# Spoken summaries of live Claude Code sessions — implementation handoff

**For:** the `voice` app (or any app that wants this feature) · **Scope:** OUTPUT leg only —
observing live Claude Code sessions and speaking a summary of each finished reply.
Transcription/sending of user input is explicitly out of scope (the host app already does it).

**Status of this design: proven.** Everything below was built and verified end-to-end in a
working prototype (Alfred, 2026-07-07): the hook fires on real interactive sessions, the
extractor was validated against 6 real transcripts, the summarizer produced good spoken
summaries, and every guard below exists because the failure it prevents actually happened
or was demonstrated.

---

## 1. Goal & UX

The app gets a **"speak Claude Code replies" toggle** in its settings. While ON and the app
is running: every time any live interactive Claude Code session finishes a turn, the user
hears a short spoken version of the reply — verbatim if it's short, an AI-generated 1–2
sentence summary if it's long. While OFF (or the app isn't running): zero side effects.

```
Claude Code session finishes a turn
        │  (official hook surface)
        ▼
 Stop hook → your script:  gates → read transcript → extract last reply
        │                              → short? verbatim : haiku summary
        ▼
 spool file (append JSONL)
        │  (polled)
        ▼
 the app speaks it (its own TTS, its own voice settings)
```

## 2. The Stop hook — Claude Code's official output surface

- A **`Stop` hook fires once per assistant turn** in every interactive session (not for
  subagents — that's the separate `SubagentStop` event).
- The hook command receives JSON on **stdin**:

  ```json
  {
    "session_id": "e0c4...",
    "transcript_path": "/Users/<u>/.claude/projects/<dashed-cwd>/<session-id>.jsonl",
    "cwd": "/Users/<u>/dev/someproject",
    "hook_event_name": "Stop",
    "permission_mode": "default"
  }
  ```

- **Configuration** lives in `~/.claude/settings.json` (user-global — the right scope for
  this feature; project-level `.claude/settings.json` also works). Exact shape:

  ```json
  {
    "hooks": {
      "Stop": [
        { "hooks": [ { "type": "command",
                       "command": "\"/path/to/your-hook-script\" --hook-stop",
                       "timeout": 30 } ] }
      ]
    }
  }
  ```

- **Timeout is 30s by default** and your script's startup time counts against it. A
  summarizer call (~3–7s) fits comfortably; keep the script's runtime light.
- **Already-running sessions do NOT pick up a newly installed hook** — only sessions
  started afterwards. Tell the user.
- Docs: https://code.claude.com/docs/en/hooks.md

## 3. Extracting the reply from the transcript

The transcript is a JSONL file (path given in the hook payload). **Its format is internal
to Claude Code and can change between versions — parse defensively**: skip anything
non-JSON or oddly shaped, and fail silent (no reply spoken beats a crash in a hook).

Verified structure (against 6 real transcripts, including 1,700-line ones):
- One JSON object per line; assistant entries have `"type": "assistant"`.
- The reply text lives in `message.content[]` blocks with `"type": "text"`.
- Turns that only ran tools have **no** text blocks.
- A turn's final text arrives as **one** assistant line (no cross-line joining needed) —
  so "the last assistant line that has non-empty text" IS the latest reply.

Reference (working, copied verbatim from the prototype):

```python
def last_assistant_text(jsonl_text: str) -> str:
    """Last assistant text message in a Claude Code transcript (format is internal - be
    defensive: skip non-JSON lines, tool-use-only turns, and anything oddly shaped)."""
    out = ""
    for line in jsonl_text.splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        blocks = (entry.get("message") or {}).get("content") or []
        txt = "".join(b.get("text", "") for b in blocks
                      if isinstance(b, dict) and b.get("type") == "text").strip()
        if txt:
            out = txt
    return out
```

## 4. Summarizing — hybrid policy

Speaking a full agentic reply aloud is tedious; always summarizing wastes 3–7s on replies
that are already one sentence. The hybrid that worked:

- **≤ 250 chars → speak verbatim** (no model call, instant).
- **Longer → summarize with `claude -p --model haiku --effort low`** (~3–7s; uses the
  user's Claude Code login — **no API key needed**).
- **If the summarizer fails** (offline, timeout): speak the first 250 chars + "…" —
  truncation beats silence.

The prompt that produced natural spoken summaries (e.g. it turned a 435-char review reply
into: *"I reviewed the pipeline, found and fixed a timing issue where the mute window was
cutting off early speech, and all tests pass—but we should do a live run to confirm
everything works."*):

```python
SUMMARY_MAX_ASIS = 250

def summarize_reply(text: str) -> str:
    """Spoken version of a session reply: short ones as-is, long ones -> 1-2 haiku sentences."""
    if len(text) <= SUMMARY_MAX_ASIS:
        return text
    prompt = (f"{text}\n\nSummarize the assistant reply above in one or two natural SPOKEN "
              "sentences (it will be read aloud). Lead with the outcome, mention any question "
              "the assistant asked. Plain text only. Always write in English.")
    try:
        r = subprocess.run(["claude", "-p", "--model", "haiku", "--effort", "low"],
                           input=prompt, capture_output=True, text=True, timeout=25,
                           env={**os.environ, "VOICE_SELF": "1"})  # see guard #1
        out = r.stdout.strip()
        if r.returncode == 0 and out:
            return out
    except Exception:
        pass
    return text[:SUMMARY_MAX_ASIS] + "..."
```

"Mention any question the assistant asked" matters: agentic replies often end by asking
the user something, and the spoken summary is how the user finds out.

## 5. Speaking

Hand the summary to the app's existing TTS (macOS `say -v <voice>` works fine as a
baseline). **The app should be the single TTS owner** — the hook must never speak
directly, or two sources of audio will overlap (see guard #5).

## 6. The five guards — hard-won, do not skip any

1. **Self-trigger loop (the nastiest one).** The summarizer's own `claude -p` call ALSO
   fires Stop hooks → your hook re-enters itself → double speech or an infinite loop.
   Fix: set a marker env var (e.g. `VOICE_SELF=1`) on **every** claude subprocess your app
   or hook spawns, and make the hook's very first line:
   `if os.environ.get("VOICE_SELF"): return`.

2. **App-running / toggle gate.** The hook is installed globally and fires for every
   session forever. It must be a **silent no-op** unless (a) the app is running — check a
   pidfile the app writes at startup (`os.kill(pid, 0)` to verify liveness) — and (b) the
   speech toggle in the app's settings is ON — the hook reads the settings file directly.

3. **Dedupe.** A turn that only ran tools produces no new text, so "last text in the
   transcript" is the PREVIOUS reply → it would be spoken twice. Store a tail of the last
   spoken raw text (e.g. last 120 chars) alongside each spool entry and skip when it
   matches.

4. **Empty turns.** No text blocks at all → return without speaking.

5. **Single TTS owner via spool.** The hook appends a JSON line to a spool file
   (`{"text": summary, "raw_tail": ..., "cwd": ...}`); the app polls the file
   (offset-based: remember file size, read only the delta; handle truncation by resetting
   the offset) and speaks new entries through its own TTS. This serializes audio, applies
   the app's voice settings, and lets the app show the summary in its UI. A real macOS app
   can use a local socket/XPC instead of a file — the spool is just the proven simple form.

Reference hook entrypoint tying it together (prototype code; rename ALFRED_SELF/paths):

```python
PIDFILE = Path("/tmp/voice.pid")            # written by the app at startup, removed on exit
SPEAK_SPOOL = Path("/tmp/voice_speak.jsonl")

def hook_stop() -> None:
    if os.environ.get("VOICE_SELF"):                      # guard 1: our own claude calls
        return
    if not speech_toggle_enabled():                       # guard 2b: app settings
        return
    try:
        os.kill(int(PIDFILE.read_text().strip()), 0)      # guard 2a: app alive?
    except Exception:
        return
    try:
        info = json.loads(sys.stdin.read() or "{}")
        tp = Path(info.get("transcript_path", ""))
        text = last_assistant_text(tp.read_text()) if tp.is_file() else ""
    except Exception:
        return
    if not text:                                          # guard 4: tool-only/empty turn
        return
    try:                                                  # guard 3: dedupe
        if SPEAK_SPOOL.is_file():
            last = SPEAK_SPOOL.read_text().splitlines()[-1:]
            if last and json.loads(last[0]).get("raw_tail") == text[-120:]:
                return
    except Exception:
        pass
    summary = summarize_reply(text)
    with SPEAK_SPOOL.open("a") as f:                      # guard 5: spool, app speaks
        f.write(json.dumps({"text": summary, "raw_tail": text[-120:],
                            "cwd": info.get("cwd", "")}) + "\n")
```

## 7. Installer

Ship a one-shot idempotent installer that merges the hook into `~/.claude/settings.json`
(never overwrite the user's other settings; detect an existing install by searching the
`Stop` entries for your command):

```python
def install_hook() -> None:
    cfg_path = Path.home() / ".claude" / "settings.json"
    cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
    stops = cfg.setdefault("hooks", {}).setdefault("Stop", [])
    if "--hook-stop" in json.dumps(stops):
        print(f"Stop hook already installed in {cfg_path}")
        return
    stops.append({"hooks": [{"type": "command",
                             "command": '"/path/to/hook-script" --hook-stop',
                             "timeout": 30}]})
    cfg_path.write_text(json.dumps(cfg, indent=2))
```

**No macOS permissions are required for this feature** (it only reads files and runs `say`).
Uninstall = remove the entry. Remind the user: only sessions started *after* install fire it.

## 8. Verification recipe (all reproducible without a live session)

1. **Fixture transcript** — write a fake JSONL with: a user line, a tool_use-only assistant
   line, an assistant line whose text is > 250 chars, a junk non-JSON line.
2. **Off-gate:** with no pidfile (or toggle off):
   `echo '{"transcript_path": "/tmp/fixture.jsonl", "cwd": "/tmp"}' | hook-script --hook-stop`
   → must exit silently, spool untouched.
3. **On-path:** write your shell's PID to the pidfile, repeat → spool gains one line whose
   `text` is a 1–2 sentence summary (this took ~7s in the prototype: script startup +
   haiku).
4. **Dedupe:** run the same command again → spool still has one line.
5. **Live:** start a NEW interactive `claude` session, ask something → on turn end the app
   speaks. Toggle speech off → next turn is silent.

## Appendix: known limitations & options

- **All sessions are spoken** while the toggle is on — any project, any window. If that's
  too chatty, gate by `cwd` allowlist or "only sessions the user has interacted with"
  (the hook payload's `cwd` + `session_id` give you what you need).
- The summary arrives a few seconds *after* the turn ends (script startup + haiku). Fine in
  practice — it's the announcement that a long agentic turn finished.
- Long-term packaging option: Claude Code **plugins** can ship hooks + background monitors
  + executables — an "install once" story if this ever becomes a standalone distribution
  (https://code.claude.com/docs/en/plugins.md).
