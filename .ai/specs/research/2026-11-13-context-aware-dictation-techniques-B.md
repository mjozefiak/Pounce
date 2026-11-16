# Context-aware dictation: techniques research (report B)

Date: 2026-11-13. Scope: techniques for a local-only, non-sandboxed macOS 26+ app (Swift 6, AppKit, Accessibility permission already used for ⌘V, local llama.cpp LLM, Parakeet/WhisperKit engines).

## How to read this report

- **FACT** — stated by the cited source. Each has a URL and a date (the source's own date when it has one, otherwise "accessed 2026-11-13").
- **INFERENCE** — my conclusion from the facts; not stated by a source.
- **UNVERIFIED** — I could not confirm it from a primary source in this session. Treat as a hypothesis to test on a real Mac.
- "Local SDK header" means the macOS SDK on the research machine (`HIServices.framework/Headers/AXUIElement.h`, `AXAttributeConstants.h`, `AXRoleConstants.h`), read on 2026-11-13. These are Apple primary sources.
- Many secondary sources below are GitHub issues and pull requests from small projects. They are useful as field reports, but each is one team's observation.

Nothing in this report was measured by me. Every latency, accuracy and reliability number is someone else's and needs a test on the target hardware before it goes into a spec.

---

## 1. macOS Accessibility API for text context

### 1.1 The API surface (all confirmed to exist)

- FACT: `AXUIElementCreateSystemWide` "is useful for things like finding the focused accessibility object regardless of which application is currently active." (Local SDK header `AXUIElement.h`, read 2026-11-13.)
- FACT: These constants exist in the SDK: `kAXFocusedUIElementAttribute`, `kAXSelectedTextRangeAttribute` (`"AXSelectedTextRange"`), `kAXStringForRangeParameterizedAttribute` (`"AXStringForRange"`), `kAXDocumentAttribute` (`"AXDocument"`), `kAXURLAttribute` (`"AXURL"`), `kAXSecureTextFieldSubrole` (`"AXSecureTextField"`). (Local SDK headers `AXAttributeConstants.h`, `AXRoleConstants.h`, read 2026-11-13.)
- FACT: `AXDocument` is "the URL of the open document represented by this accessibility object", returned as a string. (Apple Carbon Accessibility Reference, 2006-02-07, mirror: https://leopard-adc.pepas.com/documentation/Accessibility/Reference/AccessibilityCarbonRef/AccessibilityCarbonRef.pdf)
- FACT: The value is a percent-encoded `file://` URL, so paths with spaces need decoding. (trycua/cua PR #3795, https://github.com/trycua/cua/pull/3795, accessed 2026-11-13.)

The usual read sequence is: system-wide element → `AXFocusedUIElement` → role and subrole → `AXSelectedTextRange` → `AXStringForRange` for a window around the caret (or `AXValue` and slice it) → `AXSelectedText`. Then the app element → `AXFocusedWindow` → `AXTitle` and `AXDocument`.

- INFERENCE: Prefer `AXStringForRange` with a bounded range over reading the whole `AXValue`. Ghostty reports "the full screen and scrollback" as its value (see 1.3), and a large document in a native editor can be megabytes.

### 1.2 Permission

- FACT: VoiceInk documents that reading selected text "requires Accessibility permission", clipboard "needs no extra permission", and screen OCR "requires Screen Recording". (https://tryvoiceink.com/docs/context-awareness, accessed 2026-11-13.)
- FACT: Wispr Flow reads app category, text before/selected/after the cursor, on-screen names and file names with the Accessibility permission only, and "takes no screenshots". (https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness, accessed 2026-11-13.)
- FACT: A sandboxed client gets `kAXErrorCannotComplete`. (Apple Developer Forums thread 96423, https://developer.apple.com/forums/thread/96423, accessed 2026-11-13.) Pounce is not sandboxed, so this does not apply.
- INFERENCE: Reading AX attributes needs only the Accessibility TCC grant that Pounce already has. No source I found reports a new TCC category for AX reads in macOS 26 or 27. I did not find Apple release notes that say so explicitly, so "no change" is UNVERIFIED.

### 1.3 Reliability by app class

| App class | What the sources say | Confidence |
|---|---|---|
| Native AppKit (`NSTextView`, `NSTextField`) | Standard text attributes work. | High (INFERENCE from the API design and every tool using it) |
| Electron (VS Code, Cursor, Slack, Discord) | The tree is off until an assistive client turns it on. | High |
| Chromium browsers | Same, but triggered by `AXEnhancedUserInterface`. | High |
| Terminal.app, iTerm2 | Expose a text area with value and selected text. | Medium (secondary sources) |
| Ghostty | Read-only AX text since 1.2.0; value is the whole screen plus scrollback. | High |
| Other GPU-drawn terminals and editors | Often expose no text role at all. | Medium |
| Warp, JetBrains IDEs | Not found. | UNVERIFIED |

**Electron**

- FACT: "Electron applications will automatically enable accessibility features in the presence of assistive technology"; on macOS, third-party assistive technology can enable them by "setting the `AXManualAccessibility` attribute programmatically" on the application element. The docs show Swift and Objective-C examples. (https://www.electronjs.org/docs/latest/tutorial/accessibility, accessed 2026-11-13.)
- FACT: Electron's own commit notes say "rendering accessibility tree can significantly affect the performance of your app" and it should not be on by default. (Electron PR #10305, https://github.com/electron/electron/pull/10305, 2017.)
- FACT (secondary): One driver project sets `AXManualAccessibility` first, falls back to `AXEnhancedUserInterface`, and waits about 500 ms the first time per process because the tree is built asynchronously. (trycua/cua PR #1756, mirror https://github.wyh1030873310.workers.dev/trycua/cua/pull/1756, accessed 2026-11-13.)
- FACT: Wispr Flow needs VS Code's "Screen Reader Optimized" mode for variable recognition in Cursor, Windsurf and VS Code, and has no toggle to turn it on itself; the user runs "Toggle Screen Reader Accessibility Mode". File tagging does not need it. (https://docs.wisprflow.ai/articles/9805771321-file-tagging, accessed 2026-11-13.)
- INFERENCE: The Monaco editor does not expose document text to AX unless screen-reader mode is on, so "text around the cursor" in VS Code and Cursor editors is not reliably available. The window title and tab names are.

**Chromium browsers**

- FACT: "Chromium turns on or off accessibility support based on whether it sees a client, such as VoiceOver, has set the AXEnhancedUserInterface attribute on the main application window." It can also be forced with `--force-renderer-accessibility`. (https://chromium.org/developers/design-documents/accessibility, accessed 2026-11-13.)
- FACT (secondary): Setting `AXEnhancedUserInterface` breaks window managers such as Magnet; Electron avoids this by listening for `AXManualAccessibility`. (Apple accessibility-dev list, September 2020, https://lists.apple.com/archives/accessibility-dev/2020/Sep/msg00007.html — I could only read the subject and search excerpt; the page returned 502 on fetch.)
- INFERENCE: Setting `AXEnhancedUserInterface` on Chrome, Arc, Brave or Edge is a real trade-off: it changes the browser's behaviour for the whole session and costs performance. It should be opt-in per app, never automatic.

**Terminals**

- FACT (secondary): iTerm2's terminal view is a focused `AXTextArea` with settable `AXValue` and `AXSelectedTextRange`. (kingb/ember PR #23, https://github.com/kingb/ember/pull/23, accessed 2026-11-13.)
- FACT (secondary): "apps that expose a proper AX text element (Terminal.app, iTerm2, VS Code, Ghostty)" let dictation tools insert directly; terminals with no text role force a clipboard fallback. (l0ng-ai/tty7 issue #899, https://github.com/l0ng-ai/tty7/issues/899, accessed 2026-11-13.)
- FACT: Ghostty merged AX support on 2025-06-15 (milestone 1.2.0). The author calls it "a very, very bare implementation", says the reported contents are "the full screen and scrollback" and that the target use is automated tooling. (https://github.com/ghostty-org/ghostty/pull/7601)
- FACT: cmux 0.61.0 exposed only `AXGroup`, `AXScrollArea` and `AXButton`; Willow Voice then refused to insert ("No text field focused"). A commenter noted that exposing the role is not enough, because the write path must respect bracketed paste, the alternate buffer and vim insert mode. (https://github.com/manaflow-ai/cmux/issues/4953, 2026-05-28.)
- FACT: GPUI apps draw each window into one Metal view and expose no accessibility tree. (cristicretu/diri PR #869, https://github.com/cristicretu/diri/pull/869, accessed 2026-11-13.) INFERENCE: this likely applies to Zed.
- FACT: Wispr documents that it "may misidentify some fields as terminals or miss a terminal pane" inside Cursor and Windsurf. (https://docs.wisprflow.ai/articles/9805771321-file-tagging, accessed 2026-11-13.)
- INFERENCE: A terminal's `AXValue` is screen text, not "the input field". There is no reliable way to tell the prompt line from output through AX. Use terminal text only for vocabulary, never as "text before the cursor" for formatting.

### 1.4 Secure fields and password managers

- FACT: The secure field subrole is `kAXSecureTextFieldSubrole` = `"AXSecureTextField"`. (Local SDK header `AXRoleConstants.h`, read 2026-11-13.)
- FACT: WebKit exposes a password field's rendered value as bullets ("AXValue: ••••"). (WebKit layout test `password-field-value-expected.txt`, https://webkit.googlesource.com/WebKit/+/87082c751936009cbc5628fdc0a9f6ad6c07a7eb/LayoutTests/accessibility/password-field-value-expected.txt, 2014.)
- FACT: Wispr states "Password field contents are never read or included in context", that standard macOS password fields are excluded automatically, and that "custom or web-based password fields may be read like normal text". It also excludes numeric-only fields, browser URL bars, placeholder text, banking and financial apps, system processes and itself. (https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness, accessed 2026-11-13.)
- FACT: `IsSecureEventInputEnabled()` is a Carbon call that other tools poll (TextExpander is named). 1Password keeps secure input on while an item is in edit mode, which stops macOS dictation. (https://openradar.appspot.com/48953777; https://1password.community/discussion/comment/405709, accessed 2026-11-13.)
- INFERENCE: The refusal check is three layered tests, any one of which stops context capture: (1) role/subrole is `AXSecureTextField`; (2) `IsSecureEventInputEnabled()` is true; (3) the frontmost bundle ID is on a deny list (password managers, Keychain Access, Passwords, banking). Web forms that build their own password box out of a plain text input defeat test 1; that gap cannot be closed from outside the browser.

### 1.5 Latency and timeouts

- FACT: `AXUIElementSetMessagingTimeout`: "Pass the system-wide accessibility object ... if you want to set the timeout globally for this process. Setting the timeout on another accessibility object sets it only for that object". Zero resets to the default. (Local SDK header `AXUIElement.h`, read 2026-11-13.)
- FACT (historical): The default was described by Apple engineers as "about a 6 second timeout" in 2003, and a developer measured about 5 s on 10.6. (https://lists.apple.com/archives/accessibility-dev/2003/Nov/msg00004.html; https://lists.apple.com/archives/accessibility-dev/2010/Nov/msg00000.html) The current default is UNVERIFIED.
- FACT: "if the main thread of the application you are requesting information from is blocked or busy then the IPC request will timeout." (Apple accessibility-dev list, December 2012, https://lists.apple.com/archives/accessibility-dev/2012/Dec/msg00023.html)
- FACT: Wispr skips context reading "if it can't finish quickly". (https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness, accessed 2026-11-13.)
- UNVERIFIED: I found no published per-call latency figures. Each AX call is a synchronous cross-process message, so cost scales with the number of calls and with how busy the target's main thread is.
- INFERENCE: Set a short global timeout (for example 0.2–0.3 s) on the system-wide element, run the capture off the main actor, cap the whole capture with a wall-clock budget, and treat a timeout as "no context". Capture at key-down so the cost hides behind the user's speech.

### 1.6 Pasteboard privacy (macOS 15.4, 26, 27)

- FACT: `NSPasteboard.AccessBehavior` was introduced in macOS 15.4 with four cases. `default`: "The default behavior for the General pasteboard is to ask upon programmatic access. All other pasteboards default to always allow access. ... Once programmatic pasteboard access triggers the first pasteboard access alert, the state automatically changes to `.ask`." `ask`: "The system will notify the user and ask for permission before granting pasteboard access. However, access that is both user originated and paste related will always be allowed". `alwaysAllow` and `alwaysDeny` are set by the user in System Settings. (https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum, accessed 2026-11-13.)
- FACT: Apple's AppKit note: the alert appears only if the access "wasn't a result of someone's input on a UI element that the system considers paste-related". New `detect` methods on `NSPasteboard` and `NSPasteboardItem` report what kinds of data are present without reading them and without the alert. `accessBehavior` is read-only. The developer preview was enabled with `defaults write <bundle id> EnablePasteboardPrivacyDeveloperPreview -bool yes`. (Collected with developer comments at https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4, 2025-05-12 with later updates.)
- FACT (developer reports on the same page): the alert's "Allow" means once, while the Settings entry ("Paste from Other Apps", with Ask/Allow/Deny) is permanent; Apple told one developer that apps should guide users to the pane in onboarding and not link to it from the dialog; `tccutil reset Pasteboard` resets it; the pane URL is `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard`.
- FACT (developer reports, same page): the feature is absent in macOS 26 unless enabled through the default; the macOS 27.2 beta 2 release notes deprecate the default and it no longer does anything, with no prompts seen.
- FACT (single report): on macOS 27.0.1 an unsigned debug build read the general pasteboard with no alert and did not appear in the pane. (ArmmGh/topstash issue #39, https://github.com/ArmmGh/topstash/issues/39, November 2026.)
- FACT: As of macOS 26 beta 4 there was no MDM control for the per-app setting. (https://developer.apple.com/forums/thread/794560, 2025.)

What this means for a read on a dictation hotkey:

- INFERENCE: A global hotkey is "user originated" but it is not "a UI element that the system considers paste-related" (that phrase describes the Paste menu item, ⌘V in the app's own responder chain and the system paste controls). So when enforcement is on, reading clipboard *contents* at hotkey time would count as programmatic access and would show the alert on first use, then follow the per-app setting.
- INFERENCE: As of November 2026 the evidence says enforcement is not active by default on macOS 26 or 27, but the API is shipped and Apple has not withdrawn it. Design for both states.
- INFERENCE: Pounce's `ClipboardPlugin` already reads the general pasteboard in the background, so the app is exposed to this change regardless of dictation. Dictation context should reuse what the clipboard plugin or its watcher already holds where possible, and otherwise check `accessBehavior` first: read only when it is `alwaysAllow` (or when enforcement is off), use `detect` methods to learn "there is text/a URL" without a prompt, and never trigger the alert in the middle of a dictation.
- UNVERIFIED: the exact Swift names of the `detect` methods. Apple says "The Swift and Objective-C APIs are different"; check the SDK before writing code.

---

## 2. Terminal and IDE context without an extension

### 2.1 Working directory

**Terminal.app**

- FACT: macOS ships `/etc/zshrc_Apple_Terminal` with an `update_terminal_cwd()` function whose comment reads "Identify the directory using a "file:" scheme URL, including the host name to disambiguate local vs. remote paths." (File read on the research machine, macOS 27, 2026-11-13.) This is the OSC 7 report.
- UNVERIFIED: that Terminal.app then exposes this URL as the window's `AXDocument`. It is widely used that way (the proxy icon in the title bar is the same value), but I found no primary source in this session. One-minute test with Accessibility Inspector.

**iTerm2**

- FACT: Session variable `path`: "The current working directory (this works without shell integration, but not if you ssh elsewhere)." `jobName`: "The name of the current foreground job (e.g., "emacs")." `jobPid`, `commandLine` ("Command line of the current foreground job") and `tty` also need no shell integration. `hostname` and `username` do need it. (https://iterm2.com/documentation-variables.html, accessed 2026-11-13.)
- FACT: Variables are reachable from scripts as `tab.currentSession.path`, and from the shell with `it2getvar`. (https://iterm2.com/documentation-scripting-fundamentals.html; https://iterm2.com/documentation-utilities.html, accessed 2026-11-13.)
- INFERENCE: Reading them from Pounce means AppleScript (Automation TCC prompt per target app) or the Python API (must be enabled by the user). Both add a permission and tens of milliseconds. The libproc route below gives the same data with no prompt.

**Ghostty**

- FACT: Ghostty 1.3.0 added an AppleScript dictionary. A terminal has `id`, `name` and `working directory`; `focused terminal of selected tab of front window` returns the active one; `input text "..." to t` sends paste-style text and `send key "enter" to t` sends a key. It is on by default (`macos-applescript = false` disables it) and is gated by Automation TCC. (https://ghostty.org/docs/features/applescript, accessed 2026-11-13.)

**Any terminal: libproc**

- FACT: `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, ...)` returns the current directory in `pvi_cdir`. (Example: https://gist.github.com/docwhat/03a77a3950a696b2bc243a6df005128f; used for this purpose in stasadance/vanitty PR #51, https://github.com/stasadance/vanitty/pull/51, accessed 2026-11-13.)
- FACT: In XNU's `proc_info.c`, `PROC_PIDVNODEPATHINFO` falls into the `default: check_same_user = CHECK_SAME_USER` branch. `proc_security_policy` first calls `mac_proc_check_proc_info`, then compares `kauth_cred_getuid` of caller and target and returns `EPERM` on a mismatch unless the caller holds `PRIV_GLOBAL_PROC_INFO`. A missing or zombie pid returns `ESRCH`. (https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c, accessed 2026-11-13.)
- INFERENCE: A non-sandboxed app can read the working directory of any process of the same user with no entitlement. A shell running as root (`sudo -s`) or another user fails with `EPERM`; handle it as "unknown". The MAC hook means a sandbox profile could deny it, which again does not apply to Pounce.
- FACT: The foreground process group of a terminal can be read without opening the tty: `proc_pidinfo` with `PROC_PIDTBSDINFO` gives `e_tpgid`, and `proc_name` resolves the name. (herdr 0.1.0, `src/platform/macos.rs`, https://docs.rs/crate/herdr/0.1.0/source/src/platform/macos.rs, accessed 2026-11-13.) `tcgetpgrp` needs an open descriptor on the tty, so it only suits the process that owns the terminal. (Apple man page, https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/tcgetpgrp.3.html)
- INFERENCE: The no-extension recipe is: frontmost app pid → child processes → for each shell, read `e_tpgid` → that process's name (`claude`, `codex`, `vim`, `nvim`, `aider`, `gemini`, `ssh`) and its `pvi_cdir`. Two real problems remain:
  1. **Which tab or pane is focused.** A terminal app has many shells. The mapping from the focused pane to a tty is app-specific: iTerm2's `tty` variable, Ghostty's `focused terminal`, Terminal.app's AppleScript `tty` of the selected tab (UNVERIFIED), or matching the window title against each candidate's directory. With one shell there is nothing to solve; with several and no mapping, the answer is ambiguous and should be treated as unknown.
  2. **Process names.** Node-based CLIs can appear as `node`. `PROC_PIDPATHINFO` (which the same source file shows needs no same-user check) and the argument list are more reliable than `proc_name`. UNVERIFIED which name each current CLI reports; test each one.
- INFERENCE: `ssh` and `tmux` as the foreground process mean the local working directory is the wrong one. Detect both and drop file-path features.

### 2.2 Editors

- FACT: Wispr's file tagging takes names from files that are "open in a tab or visible in the sidebar". (https://docs.wisprflow.ai/articles/9805771321-file-tagging, accessed 2026-11-13.) INFERENCE: that is an AX tree walk over tab and explorer elements, which works without screen-reader mode because it is the Chromium UI, not Monaco's text.
- CONFLICTING: One developer write-up says VS Code and Cursor expose the open file through `AXDocument`, and also that Electron apps expose nothing until `AXManualAccessibility` is set. (https://dev.to/sarmaasis/how-i-built-a-mac-app-that-hands-your-screen-to-claude-code-codex-and-cursor-2di0, accessed 2026-11-13.) UNVERIFIED either way; test on the target versions.
- UNVERIFIED (prior knowledge, not re-checked): VS Code's default `window.title` puts the active file name first and the workspace folder name after a separator, and the user can change it. Treat a title parse as a hint only.
- INFERENCE: For a native document app, `AXDocument` on the focused window is the best single source of "this file". For Electron editors, use the title plus a tab-name walk, and do not claim a full path unless one was actually read.

### 2.3 Mention syntax in coding agents

**Claude Code** (primary docs)

- FACT: "Use @ to quickly include files or directories without waiting for Claude to read them." Example: `Explain the logic in @src/utils/auth.js`. "File paths can be relative or absolute." "Type `@` to open a path suggestion menu, then press Enter or Tab to accept the highlighted path and Enter again to send the message." "Directory references show file listings, not contents." Several files can be referenced in one message. The file is included when it fits the Read tool's limit (25,000 tokens by default); a text file over 256 KB is not included. `@server:resource` references MCP resources. (https://code.claude.com/docs/en/common-workflows#reference-files-and-directories, accessed 2026-11-13.)
- FACT: `@` is listed as "File path mention — Trigger file path autocomplete". (https://code.claude.com/docs/en/interactive-mode, accessed 2026-11-13.)
- FACT: Expansion happens in the client on submit, with no tool call: "Your `PreToolUse` hooks don't run when Claude Code includes a file you reference with `@`, because it makes no tool call." `CLAUDE_CODE_DISABLE_FILE_MENTIONS=1` (v2.1.299+) makes Claude receive only the paths. (Same page; https://code.claude.com/docs/en/env-vars, accessed 2026-11-13.)
- FACT: Pasting "more than 800 characters or more than three lines" collapses the input to `[Pasted text #N +M lines]`, and Claude is told that such content was pasted, "can contain instructions you didn't write", and to follow them only where the typed message asks. (https://code.claude.com/docs/en/terminal-config#paste-large-content, accessed 2026-11-13.)
- FACT: Wispr documents that in terminal areas "`@filename` text is pasted instead of attaching a file", and that long dictations pasted into the Claude Code and Codex CLIs keep only plain text. (https://docs.wisprflow.ai/articles/9805771321-file-tagging, accessed 2026-11-13.)
- FACT (third party): an integrator reports that an `@path` token in submitted prompt text is expanded into the file's contents, and expected the same for text delivered by tmux paste, pending their own probe. (bradbrok/PinkyBot issue #1414, https://github.com/bradbrok/PinkyBot/issues/1414, 2026.)
- INFERENCE: For Claude Code, a pasted literal `@relative/path` works without the picker, because resolution happens on the submitted text. The path must be correct relative to the session's working directory (or absolute). Two consequences:
  - Keep dictations with mentions under 800 characters and three lines, or the paste collapses into a placeholder. Whether `@` tokens inside a collapsed paste are still expanded is UNVERIFIED and should be assumed not to work.
  - A wrong fuzzy match is worse here than in a GUI: the wrong file's contents are silently attached. Only emit `@path` for a path that was verified to exist on disk.
- UNVERIFIED: the exact characters allowed in an unquoted `@path` (spaces, parentheses) and any quoting form. Test before supporting paths with spaces.

**Cursor**

- FACT: "Type @ in the chat input to attach specific context"; typing after `@` shows matching files and folders (`@auth.ts`, `@src/components/`). (https://cursor.com/docs/context/mentions, accessed 2026-11-13.)
- FACT: Wispr: matches "become @-tags and replace the trigger word"; "slow autocomplete may pick the wrong file, so check each attachment". File tagging works in Cursor and Windsurf chat only, not VS Code with Copilot. (https://docs.wisprflow.ai/articles/9805771321-file-tagging, accessed 2026-11-13.)
- INFERENCE: In Cursor an attachment is a UI "pill", so pasted `@name` text is not an attachment. Wispr's warning about slow autocomplete implies it types `@` plus the name and accepts the first suggestion with a key press. That mechanism is not documented; it is my reading of the warning. It needs per-app timing and can pick the wrong file.

**Codex CLI, Gemini CLI, aider**

- FACT (docs mirror): Codex CLI: "Typing @ triggers a fuzzy-filename search over the workspace root. Use up/down to select among the results and Tab or Enter to replace the @ with the selected path." (https://docs.onlinetool.cc/codex/docs/getting-started.html, accessed 2026-11-13.) INFERENCE: the result in the prompt is a plain path, so pasting a correct relative path (without `@`) is equivalent. UNVERIFIED against OpenAI's own current docs; a later release reportedly unified the picker with plugins and skills.
- FACT: Gemini CLI: "If you know the path to the file you want to work on, use the @ symbol. This forces the CLI to read the file immediately and inject its content into your prompt." A directory path is passed to the model to list with its tools. Spaces need a backslash. `.gitignore` and `.geminiignore` are respected. (https://geminicli.com/docs/cli/tutorials/file-management/; https://geminicli.com/docs/reference/commands/, accessed 2026-11-13.)
- FACT: aider: `/add` — "Add files to the chat so aider can edit them or review them in detail"; `/read-only` adds reference files. (https://aider.chat/docs/usage/commands.html, accessed 2026-11-13.) INFERENCE: aider needs a separate command line before the prompt, so "mention inline" does not map; the cheapest support is a plain relative path in the text.

### 2.4 How competitors do it

- FACT: Wispr launched file tagging in late July 2025 and "variable recognition" on 2025-08-28. (https://roadmap.wisprflow.ai/changelog/introducing-file-tagging-with-flow-in-cursor-tada; https://roadmap.wisprflow.ai/changelog/variable-recognition-for-developers-with-file-tagging-already-built-in)
- FACT: Wispr's matching rule: say the full file name with its extension, or put a trigger word ("tag", "tagged", "at", "@") before the base name. Matching ignores capitalization, separators, camelCase, quotes and backticks. If nothing matches, the words stay unchanged. Dot-prefixed names need the word "dot"; names without a dot such as `Makefile` cannot be tagged. Tagging is skipped for dictations where a dictionary or snippet substitution happened. (https://docs.wisprflow.ai/articles/9805771321-file-tagging, accessed 2026-11-13.)
- FACT: VoiceInk captures context when recording starts (selected text through Accessibility, clipboard text, and an OCR of the active window with Vision), and passes it to the enhancement prompt in tags `<CURRENTLY_SELECTED_TEXT>`, `<CLIPBOARD_CONTEXT>`, `<CURRENT_WINDOW_CONTEXT>`. Saved history "can include the extracted context text that was sent". (https://tryvoiceink.com/docs/context-awareness, accessed 2026-11-13.)
- FACT: Superwhisper has three context types: selected text (captured when recording starts; the app must keep focus), application context (text from active input fields, names and the window title, captured after transcription, plus date, the user's full name and computer name), and clipboard (text copied shortly before or during dictation). (https://superwhisper.com/docs/modes/super; https://superwhisper.com/docs/common-issues/context, accessed 2026-11-13.)
- FACT (vendor claim): Aqua reads the active screen through accessibility APIs and biases transcription toward identifiers in the open editor; its first release "used matching heuristics that were too aggressive". (Search excerpt of https://aquavoice.com/blog/building-voice-model-for-code; the page returned 404 on fetch, so this is UNVERIFIED at the source.)

---

## 3. ASR contextual biasing

### 3.1 Parakeet TDT through FluidAudio

- FACT: FluidAudio has "CTC-based custom vocabulary boosting". API: `CtcModels.downloadAndLoad()`, `CtcKeywordSpotter(models:)`, `CustomVocabularyContext(terms:)` with `CustomVocabularyTerm(text:aliases:)`, passed to `asrManager.transcribe(_:customVocabulary:)`. When an alias or the canonical text matches, the canonical form is written. (https://docs.fluidinference.com/asr/custom-vocabulary, accessed 2026-11-13.)
- FACT: It runs two encoders on the same audio: Parakeet TDT 0.6B for the transcript and Parakeet CTC 110M for per-frame log-probabilities, both at about 40 ms per frame; a rescorer then checks spotted terms against the transcript. Defaults: `defaultMinSpotterScore` −15.0, `defaultMinVocabCtcScore` −12.0, `defaultCbw` 3.0, `defaultMinSimilarity` 0.52. (Same page.)
- FACT: "Batch only" with Parakeet TDT; not available for streaming Parakeet EOU, because 160–320 ms chunks are too short for reliable spotting. (Same page.)
- FACT: Vocabulary size guidance: 1–50 terms "excellent", 50–100 "good, with no noticeable latency", 100–230 "tested". Peak RAM about 66 MB for TDT only and about 130 MB with CTC. Earnings22 (771 files, 3.2 h): RTFx 63.4x with boosting against 156x without; vocabulary precision 99.3% (8 false positives), recall 85.2%, F-score 91.7%. (Same page.)
- FACT: The method follows NVIDIA's "Fast Context-Biasing for CTC and Transducer ASR models with CTC-based Word Spotter" (Andrusenko et al., arXiv:2406.07096, 2024-06-11, Interspeech 2024, https://arxiv.org/abs/2406.07096).
- FACT: FluidAudio v0.15.6 release notes mention "vocabulary boosting on the unified Parakeet path (#862)". (Search excerpt of https://github.com/FluidInference/FluidAudio/releases, accessed 2026-11-13.) The version that first added the feature is UNVERIFIED; a downstream project used it with 0.13.4. Pounce pins 0.18.2, which is later than all of these.
- INFERENCE and open points for Pounce:
  - The CTC 110M model is a second download, so `ModelCatalog` needs a new pinned package. `CtcModels.downloadAndLoad()` must not be used (the project rule is local loading through `ModelManager` only); whether FluidAudio 0.18.2 offers a local-load entry point for the CTC models is UNVERIFIED — check the source.
  - Pounce builds FluidAudio with `traits: []`. Whether the CTC spotter is included with no traits is UNVERIFIED.
  - Pounce feeds VAD segments to the engine while recording. "Batch" here means per call, so per-segment calls should qualify, but short segments have the same boundary weakness the docs describe for streaming chunks. Test with real segments.
  - The benchmark vocabulary is company names in English earnings calls. Code identifiers (`useState`, `kubectl`), file names and Polish speech are a different distribution; no source measures them.
  - 100–230 terms is the tested ceiling. A project's file list is thousands of names, so the vocabulary must be chosen per dictation (open tabs, visible names, recent files), not dumped.

### 3.2 WhisperKit prompt biasing

- FACT: WhisperKit accepts `promptTokens` in `DecodingOptions`; the common pattern is to tokenize the prompt, strip special tokens, and set `usePrefillPrompt = true`. A bug was reported where supplying `promptTokens` returned empty text because the prefill cache was disabled and decoding stopped on an early end-of-text; a fix was proposed in PR #428. (Mirror of https://github.com/argmaxinc/WhisperKit/pull/428, accessed 2026-11-13.) Whether the fix is in WhisperKit 1.1.1 is UNVERIFIED — test it.
- FACT: OpenAI's guidance: the prompt is limited to 224 tokens and only the last 224 are used; it can be a fictitious "previous transcript" used as a spelling guide; Whisper "doesn't follow instructions like a general-purpose text model"; the techniques are "not especially reliable". (https://developers.openai.com/cookbook/examples/whisper_prompting_guide; https://developers.openai.com/api/docs/guides/speech-to-text, accessed 2026-11-13.)
- FACT: A biasing list in the prompt reduced rare-word WER from 23.7% to 18.0% in one study, which also says "the prompt for Whisper is misaligned for the instruction of contextual biasing"; fine-tuning did much better. (arXiv:2502.11572, 2025, https://arxiv.org/pdf/2502.11572)
- FACT: With more than 1000 bias words the effect "becomes largely diluted", and foundation-model biasing is "extremely sensitive to the quantity of bias words". (Hou et al., Interspeech 2025, https://www.isca-archive.org/interspeech_2025/hou25_interspeech.pdf)
- FACT (single user report): a name in the prompt ("Artem") caused "startup" to be misrecognized. (https://discuss.huggingface.co/t/adding-custom-vocabularies-on-whisper/29311, accessed 2026-11-13.)
- FACT: Argmax sells a separate "Custom Vocabulary" feature in its Pro SDK, which is a different mechanism from prompting. (https://app.argmaxinc.com/docs/examples/custom-vocabulary, accessed 2026-11-13.) It is not part of the open-source WhisperKit that Pounce uses.
- UNVERIFIED: I found no paper that measures prompt text leaking into the transcript on silence or short audio. It is a commonly reported failure, and Pounce's `RepetitionFilter` exists for a related one, but I cannot cite numbers.
- INFERENCE: Use the prompt for a short list (10–30 terms, most likely last, since only the tail counts), written as a natural sentence in the dictation language. Never put screen text or the clipboard in it verbatim: it is not an instruction channel, it can leak into output, and it biases toward similar-sounding words.

### 3.3 Post-ASR correction

- FACT: LLM correction over-corrects: "direct LLM invocation often induces hallucinatory over-correction" (arXiv:2505.24347, 2025, https://arxiv.org/pdf/2505.24347). LLMs "can overcorrect when ASR outputs are already accurate, sometimes increasing word error rate"; adding word-level ASR confidence to the prompt gave a 10% relative WER reduction over naive correction (arXiv:2509.25048, 2025, https://arxiv.org/html/2509.25048v1).
- FACT: For noisy ASR text, Double Metaphone plus grapheme-to-phoneme features and n-best hypotheses are an established entity-resolution approach when the audio's phonetics are not available. (Raghuvanshi et al., EMNLP 2019 demo, https://aclanthology.org/D19-3011.pdf)
- FACT: A production write-up layers normalized exact match, then Double Metaphone, then Levenshtein scoring for name matching. (ML6, https://www.ml6.eu/en/blog/why-voice-ai-fails-at-name-matching-and-how-we-achieved-96-accuracy, accessed 2026-11-13.) The "96%" is the vendor's own figure.
- FACT: Wispr's shipped rule is conservative: a file is tagged only on the full name with extension or after an explicit trigger word, and unmatched words are left unchanged. (See 2.4.)
- INFERENCE on false substitutions: fuzzy replacement of ordinary words by identifiers is the main risk ("index" → `index.ts`, "user" → `User`). The evidence points to these guards:
  1. Replace only inside a marked span: after a trigger word ("file", "plik", "at", "tag") or when the user says the extension ("dot ts").
  2. Require a unique best candidate with a margin over the second one; on a tie, do nothing.
  3. Match on normalized tokens (split camelCase, snake_case, kebab-case; fold diacritics) before any phonetic step. Double Metaphone is English-centred; for Polish speech, token and edit-distance matching on the normalized form is the safer base. This last point is my inference, not a cited result.
  4. Keep the vocabulary small and scoped to the current context.
  5. Show what was replaced and make it undoable.
- INFERENCE: Deterministic matching in Swift (`PounceCore` already has `TextNormalizer` and `FuzzyMatcher`) is preferable to asking a 1–4B model to "fix identifiers", given the over-correction evidence.

---

## 4. LLM post-processing with context on small local models

Note: the brief's "Qemma 3/3n" is read as Gemma 3 / 3n.

### 4.1 Context as data, not instructions

- FACT: "Spotlighting" (Hines et al., Microsoft, arXiv:2403.14720, March 2024, https://arxiv.org/abs/2403.14720) defines three ways to mark untrusted input: delimiting, datamarking (interleaving a marker token through the text) and encoding (for example Base64). Reported attack success fell from over 50% to under 2%, with datamarking and encoding stronger than delimiting, and the authors suggest randomized markers. Encoding depends on model strength: GPT-3.5-Turbo lost task quality where GPT-4 did not. (Result figures are from summaries of the paper, https://www.emergentmind.com/papers/2403.14720; check the paper's tables before quoting them.)
- FACT: Claude Code marks pasted text as pasted and tells the model that "a paste can contain instructions you didn't write, and to follow instructions inside it only where the message you typed asks it to." (https://code.claude.com/docs/en/terminal-config#paste-large-content, accessed 2026-11-13.) It also strips invisible Unicode (tag characters, bidirectional controls, zero-width spaces) before sending. (https://code.claude.com/docs/en/interactive-mode, accessed 2026-11-13.)
- FACT: VoiceInk passes context in named tags. (See 2.4.)
- INFERENCE: The spotlighting results are for large hosted models. A 1–4B model follows delimiters less reliably, and encoding is out (the paper's own GPT-3.5 result). I found no study of indirect prompt injection against a dictation-cleanup model. So do not rely on the prompt alone:
  1. **Reduce what the model sees.** Most features need no raw context in the LLM at all: file mention resolution, vocabulary correction, per-app formatting choice and "insert clipboard" can all be done in Swift. Give the model derived, low-entropy fields (app category, "cursor is mid-sentence", language) rather than screen text.
  2. **Never let the model copy context into the output.** For "what I copied", the model emits a placeholder or an intent and Swift substitutes the clipboard text afterwards. Injected text in the clipboard then cannot change anything except its own insertion.
  3. **Constrain the output** with a grammar so that the model can only produce a fixed intent set (4.3).
  4. **Check the result** with the existing `FormatterGuard` idea: reject output that is much longer than the input, that adds content words absent from the transcript and the allowed vocabulary, or that contains context text which the transcript did not.
  5. Sanitize context before use: cap length, strip control and invisible characters, and drop anything that looks like a chat-template token.
- INFERENCE on blast radius: the cleanup model has no tools, so a successful injection can only corrupt the inserted text. That changes when voice commands exist. A command that presses Return, or text inserted into a terminal or an agent prompt, turns a corrupted output into an action. Commands must therefore be decided from the transcript only, never from model output that context could have influenced.

### 4.2 Keeping the model from "answering" the dictation

- FACT: Wispr separates the two: Command Mode has its own shortcut, and "saying 'Hey Flow' or a search phrase during normal dictation does not start Command Mode". (https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode, accessed 2026-11-13.)
- FACT: Wispr's CTO describes the general problem as LLMs having "strong recall but low precision" for style rules. (https://wisprflow.ai/post/technical-challenges, 2025-09-11.) The post does not cover instruction-following in dictated text.
- UNVERIFIED: I found no primary source that measures how often small models answer a dictated question instead of cleaning it.
- INFERENCE: patterns that fit Pounce's existing `CleanupPrompt`, `Segmenter` and `FormatterGuard`: wrap the transcript in its own delimited block and state that it is text to rewrite; add few-shot examples where the transcript is a question or an order ("write me an email to…") and the output is the same sentence cleaned; cap `n_predict` at a small multiple of the input tokens; use greedy sampling (already the case); and reject by length ratio and word overlap, falling back to the raw chunk (already the policy).

### 4.3 Structured output for intents

- FACT: "GBNF (GGML BNF) is a format for defining formal grammars to constrain model outputs in llama.cpp." The server accepts `grammar`, `json_schema` and `response_format`. "The JSON schema is only used to constrain the model output and is not injected into the prompt", so the structure must also be described in the prompt. Only a subset of JSON Schema converts; "Unsupported features are skipped silently". `x? x? x?...` patterns "may result in extremely slow sampling"; use `x{0,N}`. (https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md; https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md, accessed 2026-11-13.)
- INFERENCE: Pounce embeds the `llama` XCFramework and does not run the server, so it would use the grammar sampler in the C API. The function names in the pinned build b11600 are UNVERIFIED here; read the headers of that release.
- INFERENCE: A grammar guarantees shape, not truth. A small model forced to choose from `{"action":"none"|"insert_clipboard"|...}` will still sometimes choose wrongly. And a cut-off generation leaves invalid JSON, so parse defensively and treat failure as `none`.
- INFERENCE: A cheaper design for a closed intent set is to make the grammar a plain alternation of a few literals, so the model emits one short token sequence. That costs a few tokens and is easy to verify.

### 4.4 Prompt caching

- FACT: llama.cpp server: `cache_prompt` (default `true`) — "Re-use KV cache from a previous request if possible"; because logits "are not guaranteed to be bit-for-bit identical for different batch sizes", it "can cause nondeterministic results". `n_cache_reuse` / `--cache-reuse` reuses chunks through KV shifting. Slots can be saved to and restored from files (`--slot-save-path`). `t_max_predict_ms` sets a time limit for generation. (https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md, accessed 2026-11-13.)
- INFERENCE: In the embedded runtime the same effect comes from keeping the context alive and not clearing the KV cache for the shared prefix; only the suffix is decoded. So order the prompt from most static to most volatile: system rules and few-shot examples → per-app style → per-dictation context → transcript. Then the static part is paid once per model load, and `KeepWarmRuntime` already keeps the model resident. Saving the prefix state to disk to skip it after a cold load is possible in principle; the API names in b11600 are UNVERIFIED.
- INFERENCE: The nondeterminism note matters for Pounce's snapshot-tested `CleanupPrompt`: tests that compare model output should not depend on cache state.

### 4.5 Speed

I did not find a trustworthy primary benchmark for these exact models on M-series. What exists:

- FACT (community thread, 2023 build, 7B-class Q4_0, secondary summary): generation about 61–83 tokens/s on M1 Max to M4 Max. (llama.cpp discussion #4167, https://github.com/ggml-org/llama.cpp/discussions/4167; figures as summarized by third parties.)
- FACT (one community test): LFM2.5 1.2B Q4_K_M on an M1 Max with llama.cpp: 208 tokens/s decode, about 1,200–1,500 tokens/s prompt processing. (https://lilting.ch/articles/lfm25-12b-jp-local-test-plan, 2026.)
- ESTIMATE, not measured: Qwen3 4B Q4_K_M on a base M2: about 52 tokens/s and 0.7 s to first token; the site says its numbers are derived from memory bandwidth. (https://llmcheck.net/models/qwen-3-4b-on-m2/, accessed 2026-11-13.)
- INFERENCE: a rough working range for planning is 30–60 tokens/s for 4B and 100–200 tokens/s for about 1B on recent base and Pro chips, with prompt processing several times faster. For a 50-word chunk (about 70–90 output tokens) that is roughly 0.4–0.9 s on a 1B model and 1.5–3 s on a 4B model, before any context is added. These are planning numbers only; run `llama-bench` and Pounce's own formatter timing on the supported Macs.
- INFERENCE: Output length dominates the cost, since cleanup re-emits the whole text. Every extra context token is cheap by comparison (prompt processing, and cacheable when static). The real levers are: skip the LLM when rules suffice, keep chunks short (the `Segmenter` already does), and start work while the user is still speaking (`prepare()` already loads the model).

### 4.6 Latency budgets

- FACT: Wispr's CTO: transcription and formatting should finish "within 700ms of the user stopping speech"; targets are under 200 ms for ASR, under 200 ms for the LLM and a 200 ms network allowance. (https://wisprflow.ai/post/technical-challenges, 2025-09-11.)
- FACT: Baseten's case study says the 700 ms figure is a p99 and that the Llama model must generate "100+ tokens in under 250 milliseconds". (https://www.baseten.co/resources/customers/wispr-flow/, accessed 2026-11-13.) That is 400+ tokens/s on datacenter GPUs.
- FACT: Third-party measurements of Wispr vary from about 500 ms to 1.8 s and come from competitors. (For example https://willowvoice.com/blog/speech-to-text-latency-benchmark, 2026.) Treat as unreliable.
- FACT: Nielsen's limits: about 0.1 s feels instantaneous, about 1 s keeps the flow of thought, about 10 s keeps attention. (Nielsen 1993, as quoted at https://www.jmduke.com/posts/response-times.html, accessed 2026-11-13.)
- UNVERIFIED: I found no controlled study of tolerance for dictation delay specifically. "Under 200 ms" and "above 700 ms breaks working memory" are vendor claims.
- INFERENCE: A local 1–4B model cannot meet Wispr's cloud LLM budget for full-text rewriting. A realistic local target is "raw or rule-formatted text within about 1 s of key-up; LLM polish only where the user chose it", with visible progress in the HUD beyond 1 s.

---

## 5. Voice commands and editing

- FACT: Talon has command mode ("speech is interpreted as commands by default"), dictation mode ("transcribed as plain text by default (although with some commands, like "comma" etc. for punctuation)") and mixed mode. In dictation mode the user says "escape" before words that would otherwise be a command ("escape press air" types "press air"). In command mode text is dictated with a prefix ("say hello world"). "scratch that" deletes the last dictated phrase if the cursor has not moved. Context-sensitive dictation (spacing and capitalization from surrounding text) "can be slow and may not work in every app", so it is suggested per application. (https://talon.wiki/Basic%20Usage/basic_usage, accessed 2026-11-13.)
- FACT (one user's notes): in Talon's dictation mode a command must be anchored to the whole utterance (`^...$`), otherwise the prose capture consumes it as text. (https://archive.ejfox.com/wiki/Talon_Voice_Control, accessed 2026-11-13.)
- FACT: Apple Voice Control has Dictation mode (default), Spelling mode and Command mode (commands only, with an on-screen indicator that dictation is off). Text commands such as "Replace cat with dog" are shared between Dictation and Spelling modes. (https://support.apple.com/guide/mac-help/mh40719/mac, accessed 2026-11-13.)
- FACT: The mode-error problem is old enough to have patents: in the wrong mode, "copy" is typed instead of executed. (US 6,581,033, "System and method for correction of speech recognition mode errors", https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/6581033)
- FACT: Wispr Command Mode: off by default (Settings → Experimental); its own hold-to-talk shortcut (Fn+Ctrl); sends "your current text box contents and any selected text" with the instruction; "If Flow can't read the selection directly, it tries copying it"; the result is pasted back without dictation formatting; with no text and no selection an editing command does nothing; with no editable box focused the result appears in a notification; Esc or Backspace cancels. The article gives no undo guidance. (https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode, accessed 2026-11-13.)
- FACT: Superwhisper uses per-mode configuration rather than inline commands. (https://superwhisper.com/docs/modes/custom, accessed 2026-11-13.)
- UNVERIFIED: Aqua's "say it differently" style editing. I found only vendor comparison pages and one mention of a "like it appears on screen" correction; no technical description.
- UNVERIFIED: I found no quantitative study of false-trigger rates when commands are mixed into dictation. The evidence is the design of the mature tools: all of them separate commands from prose by mode, hotkey, escape word or whole-utterance anchoring.
- INFERENCE: design rules that follow from that evidence:
  1. A separate hotkey or modifier for command and edit mode. It also solves "do not answer the dictation": the mode is known before the model runs.
  2. In dictation mode, accept only a small closed set of commands, only as the whole final segment after a pause ("press enter", "new line", "scratch that"), matched by rules on the transcript and not by the LLM. `RecordingGesture` and the VAD segments already give the segment boundary.
  3. An escape form to type a command phrase literally.
  4. Never auto-submit in terminals or agent prompts unless the user enabled it for that app; "press enter" in a shell is not undoable.
  5. Show the recognized command in the HUD, and offer undo for anything that changed text.
  6. Commands per language: the Polish forms need their own list and tests; nothing in the sources covers Polish.

---

## 6. Text insertion beyond ⌘V

### 6.1 Setting `AXSelectedText`

- FACT (developer guide): writing `kAXSelectedTextAttribute` replaces the selection, or inserts at the caret when nothing is selected, and leaves the clipboard alone. (https://levelup.gitconnected.com/swift-macos-insert-text-to-other-active-applications-two-ways-9e2d712ae293, accessed 2026-11-13.)
- FACT (field reports): in Chromium and Electron fields the attribute reports as settable and the call returns success, but no text appears. (4cecoder/talkies PR #238 and #240, https://github.com/4cecoder/talkies/pull/238; ryan-stoffel/quoth issue #41, https://github.com/ryan-stoffel/quoth/issues/41, accessed 2026-11-13.)
- FACT (field reports): the reverse also happens. Telegram inserts the text but returns `kAXErrorFailure` (−25200), so a retry inserts it twice. Reading back immediately after the write can miss a write that has not landed yet, with the same double insertion. (dojdikkkkkk/WhisperKey issue #6, https://github.com/dojdikkkkkk/WhisperKey/issues/6; saurabhav88/EnviousWispr issue #2652, https://github.com/saurabhav88/EnviousWispr/issues/2652, accessed 2026-11-13.)
- FACT: some terminals accept `AXValue` or `AXSelectedText` writes as typed input. (manaflow-ai/cmux PR #15262, https://github.com/manaflow-ai/cmux/pull/15262, 2026-09-30.) The concern raised there is that such a write bypasses bracketed paste and terminal modes. (https://github.com/manaflow-ai/cmux/issues/4953)
- UNVERIFIED: undo behaviour after an AX write. No source covers it. In native text views the write may not register with the undo manager the way typing or pasting does; test per app.
- INFERENCE: AX insertion is worth having only as an opt-in path for an allow list of verified native apps. Its one clear advantage is not touching the clipboard. As a default it has two failure modes (silent no-op, and success reported as failure) that both end in lost or doubled text.

### 6.2 Typing with `CGEvent.keyboardSetUnicodeString`

- FACT: only about 20 UTF-16 units per event are delivered in practice; tools split text into chunks of 20 and avoid splitting surrogate pairs. (https://forum.qt.io/topic/46579; typechar crate docs, https://docs.rs/crate/typechar/1.1.0, accessed 2026-11-13.) The limit is not in Apple's documentation.
- FACT: An Apple DTS engineer called the API "always problematic"; emoji and non-BMP characters failed on Monterey; posting surrogate pairs hung Pages, Keynote and Numbers in 2012. (https://developer.apple.com/forums/thread/706245; https://lists.apple.com/archives/cocoa-dev/2012/Aug/msg00397.html)
- INFERENCE: trade-offs against ⌘V:

| | ⌘V (current) | Unicode typing | AX write |
|---|---|---|---|
| Clipboard | Overwritten, then restored | Untouched | Untouched |
| Speed | Instant for any length | Slow for long text; needs pacing | Instant |
| Terminals | Bracketed paste: safe for multi-line, no accidental execution | Newlines act as Return and run commands; triggers shell autocomplete and editor auto-indent | App-specific |
| Electron / browsers | Works | Works; autocorrect and auto-pairing interfere | Often a silent no-op |
| Undo | Usually one step | Many steps, app-dependent | Unknown |
| Keyboard layout | Needs a layout-aware V (Pounce already has it) | Layout-independent | Not applicable |

- INFERENCE: Typing is the right tool for short strings that must behave like keystrokes: `@name` in Cursor's chat so the picker opens, and key commands (Return, Tab). ⌘V stays the default for prose.

### 6.3 Replacing a selection ("rewrite this")

- INFERENCE: read `AXSelectedText`; if it is empty or unreadable, fall back to a synthetic ⌘C with a pasteboard change-count check, as Wispr documents ("If Flow can't read the selection directly, it tries copying it"). Then paste the result over the still-active selection. Before pasting, confirm that the frontmost app and focused element are the same as at capture; if not, do not paste — show the result in the HUD or leave it on the clipboard (Wispr shows a notification when no editable box is focused).

### 6.4 Undo of an insertion

- FACT: Talon's "scratch that" works only "if the cursor hasn't moved". (https://talon.wiki/Basic%20Usage/basic_usage, accessed 2026-11-13.)
- FACT: Wispr offers "paste last transcript" as recovery rather than a generic undo. (https://docs.wisprflow.ai/articles/9805771321-file-tagging, accessed 2026-11-13.)
- INFERENCE: two mechanisms, neither reliable everywhere:
  1. Post ⌘Z once after a ⌘V insertion. Good in native and most Electron fields, where a paste is one undo step. Wrong in terminals (no undo; in a shell ⌘Z does nothing useful and in vim it is not undo), and wrong if the user typed anything since.
  2. Select backward by the inserted length and delete. Needs a readable `AXSelectedTextRange` to confirm that the caret is still at the end of the inserted text; otherwise it deletes the wrong characters.
- INFERENCE: offer undo only within a short window and only if focus and (where readable) the caret position are unchanged. For rewrite commands keep the original text in memory until the next dictation, so "restore original" does not depend on the target app's undo stack. This fits the existing "paste last raw" feature and the in-memory-only rule.

---

## 7. Privacy and trust patterns

- FACT: nspasteboard.org defines marker types: `org.nspasteboard.TransientType` (content is on the pasteboard only momentarily), `org.nspasteboard.ConcealedType` (confidential; do not store, or encrypt) and `org.nspasteboard.AutoGeneratedType` (not copied by the user). Maccy ignores all three by default. (https://nspasteboard.org/; https://github.com/p0deje/Maccy/blob/master/README.md, accessed 2026-11-13.)
- FACT: Raycast: "passwords copied from any password managers and other transient data are ignored by default"; Passwords and Keychain Access are excluded out of the box; users add bundle IDs under "Disable Applications". (https://manual.raycast.com/clipboard-history; https://raycast.com/core-features/clipboard-history, accessed 2026-11-13.) Alfred ignores Keychain Access and 1Password by default. (https://www.alfredapp.com/help/troubleshooting/clipboard-history/, accessed 2026-11-13.)
- FACT: Password manager coverage of the concealed marker is uneven; the 1Password Safari extension was reported not to set it the way the desktop app does. (https://www.1password.community/discussions/1password/safari-extension-doesnt-set-macos-pasteboard-type-like-desktop-app/45149, accessed 2026-11-13.)
- FACT: Wispr: captured text, extracted names and counts "are cleared when each dictation ends"; window titles "are never written to logs"; there is one global Context Awareness toggle plus an admin lock on Enterprise; its docs say nothing about private browsing. (https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness, accessed 2026-11-13.)
- FACT: VoiceInk's history can store the context that was sent. (https://tryvoiceink.com/docs/context-awareness, accessed 2026-11-13.) This is the pattern to avoid.
- FACT: Safari's AppleScript dictionary does not say whether a window is private. (https://alexwlchan.net/2021/detect-private-browsing/, 2021.) A Keyboard Maestro macro checks whether the front window's title contains "Private" (tested on Safari 18.6). (https://forum.keyboardmaestro.com/t/smart-safari-private-window-tab-opener-opens-new-tab-if-already-private/41634, 2025.)
- UNVERIFIED (prior knowledge): Chrome's AppleScript window class has a `mode` property with the value `incognito`. Using it needs the Automation permission. I found no documented window-title convention for incognito in Chromium browsers.
- INFERENCE: private-window detection has no reliable, permission-free API. It is a localized title heuristic in Safari and an Automation-gated query in Chrome. Offer it as best effort, and give users the dependable control instead: a per-app switch, including "never read context in browsers".
- INFERENCE: trust rules that fit Pounce's existing rules (clipboard contents never logged, dictated text never logged, audio in memory only):
  1. Context is read only on the dictation key press. No polling and no background observers.
  2. Context lives in memory for one dictation and is dropped when it ends. It never goes to `dictation.sqlite`, the logs, `ranking.sqlite` or crash reports. If the history later needs to explain a result, store which *sources* were used, not their text.
  3. Per-source toggles (window title, text around cursor, selection, clipboard, terminal directory and process, file names) and per-app allow/deny, with a default deny list. Reuse `CaptureFilter`'s ignored-apps list and the concealed/transient check from `ClipboardPlugin` so there is one policy.
  4. Hard refusals that the user cannot turn off: secure text fields, secure event input active, Pounce's own windows.
  5. A transparency line in the HUD naming the sources used for this dictation.
  6. Local only: with the built-in LLM nothing leaves the Mac. If the user's formatter is "My server" on loopback, context goes to that server; say so in the settings text.

---

## Recommended technical approach for a local-only implementation

Everything here is INFERENCE from the facts above. The order is by value per unit of risk.

**A. One context snapshot, taken at key-down, with a hard time budget**

1. Run the capture off the main actor with a short AX messaging timeout set once on the system-wide element and a total wall-clock cap. On timeout, continue with no context.
2. Tier 0, no AX: frontmost bundle ID and name (`WorkspaceClient`). This alone drives per-app formatting profiles.
3. Tier 1, AX on the focused element and window: role and subrole, window title, `AXDocument`, selected text, and a bounded window of text around the caret through `AXStringForRange`.
4. Tier 2, terminals: child processes of the frontmost terminal through libproc → foreground process name and working directory. Use it only when the focused pane can be mapped to one shell (single shell, or an app-specific mapping).
5. Tier 3, clipboard: only when `accessBehavior` allows it without a prompt (or enforcement is off); otherwise only `detect` results, or what `ClipboardPlugin` already holds.
6. Before anything else, apply the refusals: secure field, secure event input, deny-listed app.
7. Do not set `AXManualAccessibility` or `AXEnhancedUserInterface` by default. Offer `AXManualAccessibility` as a per-app opt-in for Electron apps and explain the cost. Do not set `AXEnhancedUserInterface` on browsers.

**B. Do the deterministic work in Swift, not in the LLM**

1. Per-app formatting profile chosen from the bundle ID and focused-field hints (terminal: no trailing period, no capital; chat: casual; mail: paragraphs).
2. Spacing and capitalization from the character before the caret, when it was read.
3. Vocabulary: build a small per-dictation term list (file names from the title, tabs and working directory; identifiers visible near the caret; names in the window). Use it three ways: FluidAudio `CustomVocabularyContext` for Parakeet (after confirming local model loading and the trait question), a short tail-weighted WhisperKit prompt, and a conservative post-ASR matcher.
4. File mentions: trigger word or spoken extension → normalized match against verified existing paths → unique winner or nothing. Emit per target: `@relative/path` pasted for Claude Code and Gemini CLI, a plain relative path for Codex CLI and aider, typed `@name` plus confirm for Cursor (opt-in, flagged as fragile).
5. "What I copied" / "this file" / "the selection": resolved by rules into placeholders that Swift fills in after any LLM step.

**C. Use the LLM narrowly**

1. Prompt order: static rules and examples → app style → small derived context → transcript, to keep the prefix cached in the warm runtime.
2. Raw context text goes to the model only for features that need it (rewrite the selection), in delimited blocks, sanitized and capped.
3. Guard every output (length ratio, word overlap, no context text that was not dictated), falling back to the raw chunk as today.
4. If intents are ever model-decided, constrain them with a grammar to a closed literal set and still gate destructive ones by rules.

**D. Commands**

1. A separate hotkey for command/edit mode.
2. In dictation mode, a short rule-matched list of trailing whole-segment commands, with an escape word.
3. No automatic Return in terminals or agent prompts unless enabled per app.

**E. Insertion and undo**

1. Keep layout-aware ⌘V with guarded clipboard restore as the default.
2. Typed Unicode (chunks of at most 20 UTF-16 units, no split surrogates) only for short picker-driving strings and keys.
3. AX insertion only as an opt-in for verified native apps.
4. Verify focus before any deferred paste; undo only within a short window with unchanged focus; keep the original of a rewrite in memory.

**F. Trust**

1. Per-source and per-app controls, a default deny list shared with `ClipboardPlugin`, fixed refusals.
2. A HUD line listing the sources used.
3. Context never persisted and never logged.

**G. Tests to run before the spec is frozen** (each resolves an UNVERIFIED item)

1. `AXDocument` on Terminal.app, iTerm2, Ghostty, VS Code, Cursor, Xcode windows.
2. What AX exposes in VS Code and Cursor without screen-reader mode; cost of `AXManualAccessibility`.
3. Per-call AX latency per app, and behaviour of a hung target with the short timeout.
4. Process names and paths reported for `claude`, `codex`, `gemini`, `aider` under libproc; `EPERM` on a root shell.
5. Pasted `@path` in Claude Code: relative, absolute, with spaces, inside a collapsed paste.
6. FluidAudio 0.18.2: local loading of the CTC models, behaviour with `traits: []`, accuracy and false positives on code identifiers and Polish speech, per-segment use.
7. WhisperKit 1.1.1: `promptTokens` returns non-empty text; leakage on silence.
8. Pasteboard: `accessBehavior` value and alert behaviour for a signed Pounce build on macOS 26 and 27.
9. `llama-bench` and formatter timings for the catalog models on the oldest supported Mac; prefix reuse in `LlamaRuntime`.
10. Undo after ⌘V and after an AX write in the top ten target apps.

## Things that will not work reliably

1. **Reading editor text in VS Code or Cursor through AX by default.** It needs screen-reader mode or a forced accessibility tree, both with user-visible cost.
2. **Reading web page text fields in Chromium browsers without `AXEnhancedUserInterface`**, and setting that flag without side effects.
3. **Telling a terminal's input line from its output through AX.** The value is the screen, sometimes with the whole scrollback.
4. **Any AX context in GPU-drawn apps with no accessibility tree** (GPUI-based apps and some newer terminals).
5. **Knowing the working directory when several shells are open and the focused pane cannot be mapped to a tty**, or when the foreground process is `ssh` or `tmux`.
6. **Detecting password fields that websites build from plain text inputs.** Only standard secure fields are detectable.
7. **Detecting private browsing windows** across browsers and languages without Automation permission.
8. **Trusting AX write results.** Chromium and Electron report success and insert nothing; some apps insert and report failure.
9. **`CGEvent` Unicode typing for long text**, and for multi-line text in terminals (each newline runs a command).
10. **A generic undo of an insertion.** It fails in terminals and after any user input.
11. **Whisper prompts as an instruction channel or as a large vocabulary.** 224 tokens, tail-weighted, not instructions, and diluted by long lists.
12. **Custom vocabulary with thousands of terms.** FluidAudio's tested range ends at about 230; biasing in general dilutes around 1000.
13. **Unrestricted fuzzy or phonetic replacement of words by identifiers.** It swaps ordinary words; Aqua reportedly shipped heuristics that were "too aggressive", and Wispr's rule is deliberately narrow.
14. **Letting a 1–4B model "fix" the transcript using screen context.** The literature reports over-correction even from large models; a small one with untrusted context is worse.
15. **Prompt-level delimiters as the only defence against injected instructions in context** on small models. The published results are for large models.
16. **Model-decided commands that execute actions**, especially Return in a terminal.
17. **Inline commands mixed freely into dictation.** Every mature tool separates them by mode, hotkey, escape word or whole-utterance anchoring.
18. **Cloud-style latency (700 ms including a full LLM rewrite) on a local 1–4B model.** The cloud figure assumes 400+ tokens/s.
19. **Attaching files in Cursor by pasting `@name`.** Attachments are picker selections; driving the picker with typed keys is timing-dependent and can pick the wrong file.
20. **Assuming clipboard reads at hotkey time stay prompt-free.** The API to restrict them has shipped since macOS 15.4; enforcement is off for now according to developer reports, and Apple has not said it is cancelled.
