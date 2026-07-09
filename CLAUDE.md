# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

# Project: yap

Two executable targets in one package:

- **`yap`** — macOS-only CLI. Apple Speech transcription (`Speech.framework`) plus a SoundAnalysis music-detection pass. Subcommands: `transcribe`, `listen`, `dictate`, `listen-and-dictate`, `mcp`. Has no networking or whisper code.
- **`yap-server`** — cross-platform HTTP server (Hummingbird). Owns the job queue, concurrency gating, and multi-backend routing. It transcribes by spawning **subprocesses**, never by linking `Speech`:
  - `apple-speech` → spawns the `yap` CLI (macOS only; probe fails elsewhere)
  - `whisper-cpp` → spawns `whisper-cli`
  - `faster-whisper` → spawns the bundled Python wrapper
  Each backend is probed at startup; only those whose binary/model resolve get registered.

## Build & Run

```bash
# macOS — builds both targets
swift build
swift run yap transcribe audio.mp3 --srt
swift run yap-server --yap-bin "$(pwd)/.build/debug/yap"

# Linux / Windows — yap target can't compile (Speech.framework), build the server only
swift build --product yap-server
```

The `apple-speech` backend uses whatever `yap` resolves on PATH unless `--yap-bin` points elsewhere. To exercise the freshly built CLI, pass `--yap-bin "$(pwd)/.build/debug/yap"`.

## Validate After Every Change

```bash
# 1. Build clean (no warnings)
swift build

# 2. Server smoke test
.build/debug/yap-server --port 8099 &
SERVER_PID=$!
sleep 2
curl -sf http://127.0.0.1:8099/health      # {"status":"ok"}
curl -sf http://127.0.0.1:8099/backends     # lists registered backends + default
kill $SERVER_PID
```

## Endpoints

`GET /health`, `GET /backends`, `POST /transcriptions` (JSON `{url,...}` or raw audio upload with query params), `GET /transcriptions/{id}`, `DELETE /transcriptions/{id}`. Job status is coarse: `queued → running → done|failed|cancelled` (no progress percentage — the subprocess contract doesn't stream progress).

## Adding a backend

Implement `TranscriptionBackend` (`Sources/yap-server/Backend.swift`) with a `probe(...) -> Self?` that returns nil when its binary/model is missing, then register it in `YapServer.buildRegistry`. Keep transcription logic in the spawned tool, not in the server.
