import copy
import json
import os
import tempfile
import unittest

import validate_gold as vg


def valid_entry():
    return {
        "schema": 1,
        "id": "synthetic-pl-01",
        "language": "pl",
        "audio": {"mic": "mic.wav", "system": "system.wav"},
        "speakers": [
            {"id": "s1", "name": "Anna", "track": "mic"},
            {"id": "s2", "name": "Bartek", "track": "system"},
        ],
        "transcript": [
            {"speaker": "s1", "start": 0.0, "end": 4.5, "text": "synthetic one"},
            {"speaker": "s2", "start": 4.5, "end": 9.0, "text": "synthetic two"},
        ],
        "english_terms": ["deploy", "pull request"],
        "key_points": [{"id": f"k{i}", "text": f"point {i}"} for i in range(10)],
        "decisions": [{"id": "d1", "text": "decision"}],
        "tasks": [
            {"id": "t1", "text": "task", "owner": "Anna", "due": "2026-12-01"},
            {"id": "t2", "text": "task two", "owner": "Bartek", "due": None},
        ],
        "consent": {"participants_agreed": True, "cloud_judges": False},
    }


class ValidateGoldTests(unittest.TestCase):
    def test_valid_entry(self):
        self.assertEqual(vg.validate_entry(valid_entry()), [])

    def test_missing_tasks_names_the_field(self):
        e = valid_entry()
        del e["tasks"]
        self.assertIn("tasks: missing", vg.validate_entry(e))
        e["tasks"] = []
        self.assertTrue(any(x.startswith("tasks: needs at least 1") for x in vg.validate_entry(e)))

    def test_missing_speakers_names_the_field(self):
        e = valid_entry()
        del e["speakers"]
        self.assertIn("speakers: missing", vg.validate_entry(e))
        e["speakers"] = []
        self.assertIn("speakers: must be a non-empty list", vg.validate_entry(e))

    def test_task_without_owner_and_bad_due(self):
        e = valid_entry()
        del e["tasks"][0]["owner"]
        e["tasks"][1]["due"] = "tomorrow"
        errors = vg.validate_entry(e)
        self.assertIn("tasks[0].owner: missing", errors)
        self.assertIn("tasks[1].due: must be YYYY-MM-DD or null", errors)

    def test_key_point_count_bounds(self):
        e = valid_entry()
        e["key_points"] = e["key_points"][:9]
        self.assertTrue(any(x.startswith("key_points: needs 10-25") for x in vg.validate_entry(e)))
        e["key_points"] = [{"id": str(i), "text": "p"} for i in range(26)]
        self.assertTrue(any(x.startswith("key_points: needs 10-25") for x in vg.validate_entry(e)))

    def test_unknown_speaker_and_owner(self):
        e = valid_entry()
        e["transcript"][0]["speaker"] = "s9"
        e["tasks"][0]["owner"] = "Ktoś"
        errors = vg.validate_entry(e)
        self.assertIn("transcript[0].speaker: not in speakers", errors)
        self.assertIn("tasks[0].owner: not a name in speakers", errors)

    def test_consent_and_language(self):
        e = valid_entry()
        e["language"] = "de"
        del e["consent"]["cloud_judges"]
        errors = vg.validate_entry(e)
        self.assertIn("language: must be one of pl|en", errors)
        self.assertIn("consent.cloud_judges: missing", errors)

    def test_audio_paths_and_files(self):
        e = valid_entry()
        e["audio"]["mic"] = "../mic.wav"
        self.assertIn("audio.mic: must be a plain file name in the entry folder", vg.validate_entry(e))
        with tempfile.TemporaryDirectory() as d:
            self.assertIn("audio.mic: file not found in the entry folder", vg.validate_entry(valid_entry(), d))
            for n in ("mic.wav", "system.wav"):
                open(os.path.join(d, n), "wb").close()
            self.assertEqual(vg.validate_entry(valid_entry(), d), [])

    def test_empty_english_terms_is_valid_but_field_is_required(self):
        e = valid_entry()
        e["english_terms"] = []
        self.assertEqual(vg.validate_entry(e), [])
        del e["english_terms"]
        self.assertIn("english_terms: missing", vg.validate_entry(e))

    def test_cli_exit_codes_and_no_text_in_output(self):
        import contextlib
        import io

        with tempfile.TemporaryDirectory() as d:
            good, bad = valid_entry(), copy.deepcopy(valid_entry())
            bad["id"] = "synthetic-bad"
            del bad["tasks"]
            for e in (good, bad):
                folder = os.path.join(d, e["id"])
                os.mkdir(folder)
                with open(os.path.join(folder, "entry.json"), "w", encoding="utf-8") as f:
                    json.dump(e, f)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = vg.main(["--no-audio-check", d])
            self.assertEqual(code, 1)
            text = out.getvalue()
            self.assertIn("FAIL synthetic-bad", text)
            self.assertIn("tasks: missing", text)
            self.assertNotIn("synthetic one", text)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(vg.main(["--no-audio-check", os.path.join(d, "synthetic-pl-01")]), 0)


if __name__ == "__main__":
    unittest.main()
