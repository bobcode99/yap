# 🗣️ yap

On-device speech transcription, shipped as two binaries:

- **`yap`** — a focused macOS CLI built on [Speech.framework](https://developer.apple.com/documentation/speech). File transcription (`transcribe`), live capture (`listen`, `dictate`, `listen-and-dictate`), an MCP server (`mcp`), and an optional music-detection pass that marks `[Music]` ranges in timed output.
- **`yap-server`** — a cross-platform HTTP server that queues transcription jobs and runs them through pluggable backends. It never links Apple frameworks; it shells out to transcription tools as subprocesses:
  - `apple-speech` → the `yap` CLI (macOS only)
  - `whisper-cpp` → whisper.cpp's `whisper-cli`
  - `faster-whisper` → the bundled Python wrapper

The server registers whichever backends are available on the host, so macOS can offer all three while Linux/Windows offer the whisper backends.

## Build

```bash
# macOS — builds both `yap` and `yap-server`
swift build -c release

# Linux / Windows — the `yap` CLI needs Speech.framework, so build the server only
swift build -c release --product yap-server
```

![Demo](https://github.com/user-attachments/assets/326de51d-5a58-4c96-9d6c-98b07e6d9e58)

### Usage

```
USAGE: yap transcribe [--locale <locale>] [--censor] <input-file> [--txt] [--srt] [--vtt] [--json] [--output-file <output-file>] [--max-length <max-length>] [--word-timestamps] [--detect-music] [--no-detect-music]

ARGUMENTS:
  <input-file>            Path to an audio or video file to transcribe.

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -o, --output-file <output-file>
                          Path to save the transcription output. If not provided,
                          output will be printed to stdout.
  -m, --max-length <max-length>
                          Maximum sentence length in characters. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  --detect-music/--no-detect-music
                          Mark detected music ranges as [Music] in timed output
                          formats (SRT, VTT, JSON). (default: --detect-music)
  -h, --help              Show help information.
```

### Music detection

By default `yap transcribe` runs a [SoundAnalysis](https://developer.apple.com/documentation/soundanalysis) pre-pass that detects music/singing ranges. In timed formats (SRT, VTT, JSON) those ranges replace any (usually garbled) speech segments with a `[Music]` marker. Plain text output is unaffected. Pass `--no-detect-music` to skip the pass.

```bash
# SRT with [Music] markers over the musical intro/outro
yap transcribe podcast.mp3 --srt -o podcast.srt

# Disable music detection
yap transcribe interview.wav --srt --no-detect-music -o interview.srt
```

> Use whisper.cpp or faster-whisper through **`yap-server`** (see below), not the CLI — the CLI is Apple Speech only.

### Installation

#### Homebrew

```bash
brew install yap
```

#### Mint

```bash
mint install finnvoor/yap
```

### Examples

#### Transcribe a YouTube video using yap and [yt-dlp](https://github.com/yt-dlp/yt-dlp)

```bash
yt-dlp "https://www.youtube.com/watch?v=ydejkIvyrJA" -x --exec yap
```

#### Summarize a video using yap and [llm](https://llm.datasette.io/en/stable)

```bash
yap video.mp4 | uvx llm -m mlx-community/Llama-3.2-1B-Instruct-4bit 'Summarize this transcript:'
```

#### Create SRT captions for a video

```bash
yap video.mp4 --srt -o captions.srt
```

#### Generate WebVTT subtitles

```bash
yap video.mp4 --vtt -o subtitles.vtt
```

#### Export JSON with word-level timestamps

```bash
yap video.mp4 --json --word-timestamps -o transcript.json
```

### Live System Audio

`yap listen` transcribes system audio in real time — anything playing on your computer.

```
USAGE: yap listen [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Screen Recording permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Screen Recording.

#### Examples

```bash
# Transcribe system audio live
yap listen

# Pipe live transcription to another tool
yap listen | uvx llm 'Translate this to French:'

# Save system audio as VTT subtitles
yap listen --vtt > captions.vtt
```

### Listen and Dictate

`yap listen-and-dictate` transcribes both system audio and microphone input simultaneously — perfect for meeting transcription.

```
USAGE: yap listen-and-dictate [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--mic-label <mic-label>] [--system-label <system-label>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --mic-label <mic-label> Speaker label for microphone audio in timed output
                          formats. (default: Mic)
  --system-label <system-label>
                          Speaker label for system audio in timed output
                          formats. (default: System)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Both Screen Recording and Microphone permissions are required. Grant them to your terminal app in System Settings > Privacy & Security.

#### Examples

```bash
# Transcribe a video call (both sides)
yap listen-and-dictate

# Save a meeting transcript
yap listen-and-dictate > meeting.txt

# Save a meeting transcript as VTT with speaker labels
yap listen-and-dictate --vtt > meeting.vtt

# Use custom speaker labels
yap listen-and-dictate --vtt --mic-label Alice --system-label Bob > meeting.vtt
```

### Dictation

`yap dictate` transcribes microphone input in real time.

```
USAGE: yap dictate [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Microphone permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Microphone.

#### Examples

```bash
# Dictate from your microphone
yap dictate

# Dictate and save to a file
yap dictate > notes.txt
```

### HTTP Server

`yap-server` is a cross-platform HTTP server that accepts audio URLs or raw audio uploads and returns transcripts asynchronously. Jobs are queued immediately and processed in the background — poll for the result when ready. Each job picks a backend (`apple-speech`, `whisper-cpp`, or `faster-whisper`); the server runs it as a subprocess.

At startup the server probes for each backend's binary/model and registers the ones it finds. On macOS with `yap` on PATH you get `apple-speech`; add a whisper model to enable the whisper backends; on Linux/Windows you get whatever whisper backends you configure.

```
USAGE: yap-server [--host <host>] [--port <port>] [--api-key <api-key>] [--max-concurrent <max-concurrent>] [--default-backend <default-backend>] [--yap-bin <yap-bin>] [--whisper-cli-bin <whisper-cli-bin>] [--whisper-model <whisper-model>] [--faster-whisper-python <faster-whisper-python>] [--faster-whisper-model <faster-whisper-model>] [--faster-whisper-device <faster-whisper-device>] [--faster-whisper-compute-type <faster-whisper-compute-type>]

OPTIONS:
  --host <host>                     Host to bind to. (default: 127.0.0.1)
  --port <port>                     Port to listen on. (default: 8080)
  --api-key <api-key>               If set, require X-API-Key header on all non-health requests.
  --max-concurrent <max-concurrent> Maximum number of concurrent transcription jobs. (default: 2)
  --default-backend <default-backend>
                                    Backend used when a request omits one.
  --yap-bin <yap-bin>               Path to the yap CLI (apple-speech). Looked up on PATH by default.
  --whisper-cli-bin <whisper-cli-bin>
                                    Path to whisper.cpp's whisper-cli. ($YAP_WHISPER_CLI_BIN)
  --whisper-model <whisper-model>   whisper.cpp model file — required to enable whisper-cpp. ($YAP_WHISPER_MODEL)
  --faster-whisper-python <faster-whisper-python>
                                    Python executable for the bundled wrapper. ($YAP_FASTER_WHISPER_PYTHON)
  --faster-whisper-model <faster-whisper-model>
                                    faster-whisper model — required to enable faster-whisper. ($YAP_FASTER_WHISPER_MODEL)
  --faster-whisper-device <faster-whisper-device>
                                    faster-whisper device, e.g. auto, cpu, cuda. (default: auto)
  --faster-whisper-compute-type <faster-whisper-compute-type>
                                    faster-whisper compute type, e.g. default, int8, float16. (default: default)
  -h, --help                        Show help information.
```

**Tuning `--max-concurrent`:**

Jobs beyond the limit are queued in memory and processed as slots free up — clients always receive a `202` immediately. The right value depends on your hardware and backend; for Apple Speech on Apple Silicon the Neural Engine serializes inference internally, so `2`–`6` is the useful range.

#### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/backends` | List registered backends and the default |
| `POST` | `/transcriptions` | Submit a transcription job → `202` with job ID |
| `GET` | `/transcriptions/{id}` | Poll job status and retrieve transcript |
| `DELETE` | `/transcriptions/{id}` | Cancel a queued or running job |

#### List backends

```bash
curl -s http://127.0.0.1:8080/backends
# → {"backends":["apple-speech"],"default":"apple-speech"}
```

#### Submit a job — URL mode

Send a JSON body with the audio URL and any options:

```bash
curl -s -X POST http://127.0.0.1:8080/transcriptions \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com/audio.mp3",
    "backend": "whisper-cpp",
    "locale": "en-US",
    "format": "srt"
  }'
# → {"id":"550e8400-…","status":"queued","backend":"whisper-cpp"}
```

**Request fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `url` | string | *required* | URL of the audio or video file to download and transcribe |
| `name` | string | — | Human-readable label for the job |
| `backend` | string | server default | `apple-speech`, `whisper-cpp`, or `faster-whisper` (must be registered) |
| `locale` | string | system locale | BCP 47 locale identifier; whisper backends use the language part |
| `format` | string | `"srt"` | Output format: `txt`, `srt`, `vtt`, or `json` |
| `censor` | bool | `false` | Replace certain words with a redacted form (apple-speech) |
| `max_length` | int | `40` | Maximum sentence length in characters for timed formats |
| `word_timestamps` | bool | `false` | Include word-level timestamps (JSON format only) |
| `detect_music` | bool | `true` | Mark music ranges as `[Music]` (apple-speech only) |

#### Submit a job — file upload mode

Send raw audio bytes with the appropriate `Content-Type`. Pass options as query parameters (same names as the JSON fields):

```bash
curl -s -X POST "http://127.0.0.1:8080/transcriptions?format=srt&backend=apple-speech&name=Episode+42" \
  -H "Content-Type: audio/mpeg" \
  --data-binary @recording.mp3
# → {"id":"550e8400-…","name":"Episode 42","status":"queued","backend":"apple-speech"}
```

Supported content types: `audio/mpeg`, `audio/wav`, `audio/mp4`, `video/mp4`, `audio/ogg`, `audio/flac`.

#### Poll for results

```bash
curl -s http://127.0.0.1:8080/transcriptions/550e8400-…
# queued:    {"id":"…","status":"queued","backend":"apple-speech"}
# running:   {"id":"…","status":"running","backend":"apple-speech"}
# done:      {"id":"…","status":"done","backend":"apple-speech","format":"srt","transcript":"1\n00:00:01,000 --> …"}
# failed:    {"id":"…","status":"failed","backend":"apple-speech","error":"…"}
# cancelled: {"id":"…","status":"cancelled","backend":"apple-speech"}
```

Status is coarse — `queued → running → done|failed|cancelled` — with no progress percentage, since each backend runs as an opaque subprocess. The `name` field is echoed back when it was set at submission time.

#### Cancel a job

Cancel any job that is still `queued` or `running`. Returns `204` on success, `404` if the job doesn't exist, and `409` if it has already finished or been cancelled.

```bash
curl -s -X DELETE http://127.0.0.1:8080/transcriptions/550e8400-…
# → 204 No Content
```

#### Examples

```bash
# macOS — apple-speech via the freshly built CLI
yap-server --yap-bin "$(pwd)/.build/release/yap"

# whisper.cpp backend
yap-server --whisper-cli-bin /opt/whisper.cpp/build/bin/whisper-cli \
           --whisper-model /models/ggml-base.en.bin

# faster-whisper backend (Linux/Windows friendly)
pip install faster-whisper
yap-server --faster-whisper-model small --faster-whisper-device cpu

# Multiple backends at once; pick per request with the "backend" field
yap-server --yap-bin yap --whisper-model /models/ggml-base.en.bin --default-backend apple-speech

# Custom port with API key auth
yap-server --port 9000 --api-key mysecret
curl -s -X POST http://127.0.0.1:9000/transcriptions \
  -H "X-API-Key: mysecret" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/podcast.mp3", "format": "txt"}'

# Transcribe a YouTube video via the server
yt-dlp "https://www.youtube.com/watch?v=ydejkIvyrJA" -x -o - | \
  curl -s -X POST "http://127.0.0.1:8080/transcriptions?format=srt" \
  -H "Content-Type: audio/mpeg" \
  --data-binary @-
```

### MCP Server

yap includes an [MCP](https://modelcontextprotocol.io) server that exposes a `transcribe` tool, allowing any MCP-compatible agent to transcribe audio and video files.

#### Claude Code

```bash
claude mcp add yap -- yap mcp
```

#### Codex

```bash
codex mcp add yap -- yap mcp
```
