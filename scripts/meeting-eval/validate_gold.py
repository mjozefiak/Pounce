#!/usr/bin/env python3
"""Validate entries of the meeting gold set (MEET-1.3).

Standard library only. Run as: python3 -I validate_gold.py [DIR | entry.json ...]
Without arguments the directory comes from LINTEL_MEETING_GOLD_DIR.

Layout: DIR/<entry id>/entry.json (+ the two audio files it names, same folder).
Never prints transcript, note or name text: only entry ids, field paths and counts.
Exit codes: 0 all entries valid, 1 some entry invalid, 2 usage/input error.
"""

import json
import os
import re
import sys

SCHEMA = 1
ENV_DIR = "LINTEL_MEETING_GOLD_DIR"
ENTRY_FILE = "entry.json"
LANGUAGES = ("pl", "en")
KEY_POINTS_MIN, KEY_POINTS_MAX = 10, 25
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
DUE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _is_text(v):
    return isinstance(v, str) and v.strip() != ""


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def validate_entry(entry, base_dir=None, folder_name=None):
    """Return a list of error strings ('<field path>: <reason>'). Empty = valid.

    base_dir: folder of the entry; when given, the audio files must exist there.
    folder_name: name of the entry folder; when given, it must equal the entry id.
    """
    errors = []

    def err(path, why):
        errors.append(f"{path}: {why}")

    def is_object(obj, path):
        if isinstance(obj, dict):
            return True
        err(path.rstrip("."), "must be an object")
        return False

    def need(obj, key, path):
        if not isinstance(obj, dict) or key not in obj or obj[key] is None:
            err(f"{path}{key}", "missing")
            return None
        return obj[key]

    if not isinstance(entry, dict):
        return ["entry: must be a JSON object"]

    schema = entry.get("schema")
    if not (isinstance(schema, int) and not isinstance(schema, bool) and schema == SCHEMA):
        err("schema", f"must be {SCHEMA}")

    eid = need(entry, "id", "")
    if eid is not None and not (isinstance(eid, str) and ID_RE.match(eid)):
        err("id", "must match [a-z0-9][a-z0-9_-]* (max 64)")
    elif eid is not None and folder_name is not None and eid != folder_name:
        err("id", "must equal the entry folder name")

    lang = need(entry, "language", "")
    if lang is not None and lang not in LANGUAGES:
        err("language", "must be one of " + "|".join(LANGUAGES))

    # audio: two tracks, relative file names inside the entry folder
    audio = need(entry, "audio", "")
    if audio is not None:
        if not isinstance(audio, dict):
            err("audio", "must be an object")
        else:
            for track in ("mic", "system"):
                name = need(audio, track, "audio.")
                if name is None:
                    continue
                if (
                    not _is_text(name)
                    or os.path.isabs(name)
                    or ".." in name.replace("\\", "/").split("/")
                    or "/" in name
                    or "\\" in name
                ):
                    err(f"audio.{track}", "must be a plain file name in the entry folder")
                elif base_dir is not None and not os.path.isfile(os.path.join(base_dir, name)):
                    err(f"audio.{track}", "file not found in the entry folder")

    # speakers
    speaker_ids = set()
    speaker_names = set()
    speakers = need(entry, "speakers", "")
    if speakers is not None:
        if not isinstance(speakers, list) or not speakers:
            err("speakers", "must be a non-empty list")
        else:
            for i, s in enumerate(speakers):
                p = f"speakers[{i}]."
                if not is_object(s, p):
                    continue
                sid = need(s, "id", p)
                name = need(s, "name", p)
                if sid is not None:
                    if not _is_text(sid):
                        err(p + "id", "must be non-empty text")
                    elif sid in speaker_ids:
                        err(p + "id", "duplicate")
                    else:
                        speaker_ids.add(sid)
                if name is not None:
                    if not _is_text(name):
                        err(p + "name", "must be non-empty text")
                    else:
                        speaker_names.add(name)
                track = s.get("track")
                if track is not None and track not in ("mic", "system"):
                    err(p + "track", "must be mic or system")

    # corrected transcript with speakers
    transcript = need(entry, "transcript", "")
    if transcript is not None:
        if not isinstance(transcript, list) or not transcript:
            err("transcript", "must be a non-empty list")
        else:
            for i, seg in enumerate(transcript):
                p = f"transcript[{i}]."
                if not is_object(seg, p):
                    continue
                sp = need(seg, "speaker", p)
                if sp is not None and not _is_text(sp):
                    err(p + "speaker", "must be non-empty text")
                elif sp is not None and speaker_ids and sp not in speaker_ids:
                    err(p + "speaker", "not in speakers")
                start = need(seg, "start", p)
                end = need(seg, "end", p)
                if start is not None and not (_is_num(start) and start >= 0):
                    err(p + "start", "must be a number >= 0 (seconds)")
                elif start is not None and end is not None:
                    if not _is_num(end) or end < start:
                        err(p + "end", "must be a number >= start")
                elif end is not None and not _is_num(end):
                    err(p + "end", "must be a number")
                text = need(seg, "text", p)
                if text is not None and not _is_text(text):
                    err(p + "text", "must be non-empty text")

    # English terms (the list may be empty; the field is required)
    terms = need(entry, "english_terms", "")
    if terms is not None:
        if not isinstance(terms, list) or not all(_is_text(t) for t in terms):
            err("english_terms", "must be a list of non-empty text")

    def check_items(key, minimum, maximum=None):
        items = need(entry, key, "")
        if items is None:
            return []
        if not isinstance(items, list):
            err(key, "must be a list")
            return []
        if len(items) < minimum or (maximum is not None and len(items) > maximum):
            rng = f"{minimum}-{maximum}" if maximum else f"at least {minimum}"
            err(key, f"needs {rng} items, has {len(items)}")
        objects = []
        seen = set()
        for i, item in enumerate(items):
            p = f"{key}[{i}]."
            if not is_object(item, p):
                continue
            item_id = need(item, "id", p)
            if item_id is not None:
                if not _is_text(item_id):
                    err(p + "id", "must be non-empty text")
                elif item_id in seen:
                    err(p + "id", "duplicate")
                else:
                    seen.add(item_id)
            objects.append((i, item))
        return objects

    # key points: 10-25
    kp = check_items("key_points", KEY_POINTS_MIN, KEY_POINTS_MAX)
    for i, item in kp:
        p = f"key_points[{i}]."
        t = need(item, "text", p)
        if t is not None and not _is_text(t):
            err(p + "text", "must be non-empty text")

    # decisions (may be empty: a meeting can decide nothing)
    dec = check_items("decisions", 0)
    for i, item in dec:
        p = f"decisions[{i}]."
        t = need(item, "text", p)
        if t is not None and not _is_text(t):
            err(p + "text", "must be non-empty text")

    # tasks: at least one, each with owner (a speaker) and a due date or null
    tasks = check_items("tasks", 1)
    for i, item in tasks:
        p = f"tasks[{i}]."
        t = need(item, "text", p)
        if t is not None and not _is_text(t):
            err(p + "text", "must be non-empty text")
        owner = need(item, "owner", p)
        if owner is not None:
            if not _is_text(owner):
                err(p + "owner", "must be non-empty text")
            elif speaker_names and owner not in speaker_names:
                err(p + "owner", "not a name in speakers")
        if "due" not in item:
            err(p + "due", "missing (use null for no due date)")
        elif item["due"] is not None and not (
            isinstance(item["due"], str) and DUE_RE.match(item["due"])
        ):
            err(p + "due", "must be YYYY-MM-DD or null")

    # participants' consent
    consent = need(entry, "consent", "")
    if consent is not None:
        if not isinstance(consent, dict):
            err("consent", "must be an object")
        else:
            for k in ("participants_agreed", "cloud_judges"):
                v = need(consent, k, "consent.")
                if v is not None and not isinstance(v, bool):
                    err(f"consent.{k}", "must be true or false")
            if consent.get("cloud_judges") is True and consent.get("participants_agreed") is not True:
                err("consent.cloud_judges", "true needs participants_agreed true")

    return errors


def load_entry(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def entry_paths(target):
    """A directory of entry folders, one entry folder, or one entry.json."""
    if os.path.isfile(target):
        return [target]
    direct = os.path.join(target, ENTRY_FILE)
    if os.path.isfile(direct):
        return [direct]
    paths = []
    for name in sorted(os.listdir(target)):
        p = os.path.join(target, name, ENTRY_FILE)
        if os.path.isfile(p):
            paths.append(p)
    return paths


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    check_audio = True
    if "--no-audio-check" in argv:
        argv.remove("--no-audio-check")
        check_audio = False
    targets = argv or ([os.environ[ENV_DIR]] if os.environ.get(ENV_DIR) else [])
    if not targets:
        print(f"usage: validate_gold.py [--no-audio-check] [DIR|entry.json ...] (or set {ENV_DIR})", file=sys.stderr)
        return 2
    paths = []
    for t in targets:
        if not os.path.exists(t):
            print(f"validate_gold: not found: {t}", file=sys.stderr)
            return 2
        paths.extend(entry_paths(t))
    if not paths:
        print("validate_gold: no entries found", file=sys.stderr)
        return 2
    bad = 0
    for p in paths:
        label = os.path.basename(os.path.dirname(os.path.abspath(p)))
        try:
            entry = load_entry(p)
        except (OSError, ValueError) as e:
            print(f"FAIL {label}: entry.json: unreadable ({type(e).__name__})")
            bad += 1
            continue
        folder = os.path.dirname(os.path.abspath(p))
        errors = validate_entry(entry, folder if check_audio else None, label)
        if errors:
            bad += 1
            print(f"FAIL {label}")
            for e in errors:
                print(f"  {e}")
        else:
            print(f"OK   {label}")
    print(f"{len(paths) - bad}/{len(paths)} entries valid")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
