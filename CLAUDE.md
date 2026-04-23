# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                          # debug build
swift build -c release               # release build
swift run yap <subcommand> [flags]   # run directly

# HTTP server (for serve development)
swift run yap serve --host 0.0.0.0 --log-level debug
```

## Validate After Every Change

Run these three checks after any code change before committing:

```bash
# 1. Build must be clean (no errors, no warnings treated as errors)
swift build

# 2. Server smoke test — start, hit all critical endpoints, kill
.build/debug/yap serve --port 8099 &
SERVER_PID=$!
sleep 2
curl -sf http://127.0.0.1:8099/health         # must return {"status":"ok"}
curl -sf http://127.0.0.1:8099/openapi.yaml | head -1   # must return "openapi:"
curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:8099/docs  # must return 200
kill $SERVER_PID

# 3. OpenAPI spec must be valid YAML
python3 -c "import yaml, sys; yaml.safe_load(open('Sources/yap/openapi.yaml'))" && echo "spec OK"
```

## Architecture

Single executable target (`Sources/yap/`) with these layers:

### CLI Commands (`Yap.swift`)
Six subcommands registered with `ArgumentParser`: `transcribe`, `listen`, `dictate`, `listen-and-dictate`, `mcp`, `serve`. All are `AsyncParsableCommand`.

### Core Transcription (`TranscriptionEngine.swift`)
Wraps Apple's `Speech.framework` (`SpeechTranscriber` + `SpeechAnalyzer`). The single entry point is:
```swift
TranscriptionEngine.transcribe(file:options:onProgress:)
```
- Downloads language models on first use via `AssetInventory`
- `onProgress` callback receives 0.0–0.99; enables real-time progress for `yap serve`
- Requires macOS 26 (`SpeechTranscriber` API)

### Output Formats (`OutputFormat.swift`)
`OutputFormat` enum handles both **buffered** (file transcription) and **streaming** (live commands) rendering for `txt`, `srt`, `vtt`, `json`. Segment splitting uses `AttributedString` runs with `.audioTimeRange` attributes.

### HTTP Server (`Serve.swift` + `APIImpl.swift`)

**Spec-first OpenAPI flow:**
1. Edit `Sources/yap/openapi.yaml` — this is the single source of truth
2. `swift-openapi-generator` build plugin auto-generates `Types.swift` + `Server.swift` into `.build/plugins/outputs/`
3. `YapAPI` in `APIImpl.swift` implements the generated `APIProtocol`
4. `Serve.swift` calls `api.registerHandlers(on: router)` — two manual routes (`/openapi.yaml`, `/docs`) are added separately

**Never manually edit the generated files** in `.build/plugins/outputs/`.

**Job lifecycle:**
```
POST /transcriptions → JobStore.create() → Task.detached (waits on AsyncSemaphore)
                     → TranscriptionEngine.transcribe() with onProgress callback
                     → JobStore.update(.running(progress:)) on each tick
                     → JobStore.update(.done / .failed) on completion
GET /transcriptions/{id} → polls JobStore
```

**API key auth** flows via `APIKeyMiddleware` → `APIKeyContext` (`@TaskLocal`) → checked in each `YapAPI` method. `/health`, `/openapi.yaml`, `/docs` skip the check.

**Concurrency:** `AsyncSemaphore(value: maxConcurrent)` (default 2) gates `Task.detached` workers. Upload bodies stream directly to a temp file (no RAM buffering) to avoid 413 on large files.

### MCP Server (`MCP.swift`)
Exposes a `transcribe` tool over the Model Context Protocol using `swift-sdk`. Labeled parameter syntax required: `.text(text:annotations:_meta:)`.

## Key Constraints

- **Platform**: macOS 26 only — `SpeechTranscriber` is unavailable on earlier versions
- **Swift 6.1 strict concurrency**: all shared state must be `actor`-isolated or `Sendable`. `@TaskLocal` is the approved pattern for passing request-scoped values into async contexts
- **`swift-sdk` version**: pinned to `.upToNextMinor(from: "0.12.0")` — earlier versions have unresolved strict concurrency errors in `NetworkTransport.swift`
- **`openapi.yaml` + `openapi-generator-config.yaml`** must both exist in `Sources/yap/` for the build plugin to run

## OpenAPI Spec Changes

When adding or modifying endpoints:
1. Edit `Sources/yap/openapi.yaml`
2. Run `swift build` — the plugin regenerates the types
3. Implement any new protocol methods in `APIImpl.swift` (the compiler will error on missing conformance)
4. Run the smoke test above to confirm `/openapi.yaml` serves the updated spec
