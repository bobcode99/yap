# 🗣️ yap

A CLI for on-device speech transcription using [Speech.framework](https://developer.apple.com/documentation/speech) on macOS 26.

![Demo](https://github.com/user-attachments/assets/326de51d-5a58-4c96-9d6c-98b07e6d9e58)

### Usage

```
USAGE: yap transcribe [--locale <locale>] [--censor] <input-file> [--txt] [--srt] [--vtt] [--json] [--output-file <output-file>] [--max-length <max-length>] [--word-timestamps]

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
  -h, --help              Show help information.
```

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

`yap serve` starts a local HTTP server that accepts audio URLs or raw audio uploads and returns transcripts asynchronously. Jobs are queued immediately and processed in the background — poll for the result when ready.

```
USAGE: yap serve [--host <host>] [--port <port>] [--api-key <api-key>]

OPTIONS:
  --host <host>           Host to bind to. (default: 127.0.0.1)
  --port <port>           Port to listen on. (default: 8080)
  --api-key <api-key>     If set, require X-API-Key header on all requests.
  -h, --help              Show help information.
```

#### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/locales` | List all supported transcription languages |
| `POST` | `/transcriptions` | Submit a transcription job → `202` with job ID |
| `GET` | `/transcriptions/{id}` | Poll job status and retrieve transcript |

#### List supported languages

```bash
curl -s http://127.0.0.1:8080/locales | jq '.locales[] | select(.installed)'
```

Response:
```json
{
  "locales": [
    { "id": "en-US", "name": "English (United States)", "installed": true },
    { "id": "fr-FR", "name": "French (France)",         "installed": false },
    { "id": "zh-TW", "name": "Chinese (Taiwan)",        "installed": false }
  ]
}
```

`installed: true` means the language model is already on disk — transcription starts immediately. `installed: false` means the model will be downloaded on first use.

#### Submit a job — URL mode

Send a JSON body with the audio URL and any options:

```bash
curl -s -X POST http://127.0.0.1:8080/transcriptions \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com/audio.mp3",
    "locale": "en-US",
    "format": "srt"
  }'
# → {"id":"550e8400-e29b-41d4-a716","status":"queued"}
```

**Request fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `url` | string | *required* | URL of the audio or video file to download and transcribe |
| `locale` | string | system locale | BCP 47 locale identifier (e.g. `"en-US"`, `"fr-FR"`) |
| `format` | string | `"srt"` | Output format: `txt`, `srt`, `vtt`, or `json` |
| `censor` | bool | `false` | Replace certain words with a redacted form |
| `max_length` | int | `40` | Maximum sentence length in characters for timed formats |
| `word_timestamps` | bool | `false` | Include word-level timestamps (JSON format only) |

#### Submit a job — file upload mode

Send raw audio bytes with the appropriate `Content-Type`. Pass options as query parameters:

```bash
curl -s -X POST "http://127.0.0.1:8080/transcriptions?format=srt&locale=en-US" \
  -H "Content-Type: audio/mpeg" \
  --data-binary @recording.mp3
# → {"id":"550e8400-e29b-41d4-a716","status":"queued"}
```

Supported content types: `audio/mpeg`, `audio/wav`, `audio/mp4`, `video/mp4`, `audio/ogg`, `audio/flac`.

#### Poll for results

```bash
curl -s http://127.0.0.1:8080/transcriptions/550e8400-e29b-41d4-a716
# while running:  {"id":"…","status":"running"}
# on completion:  {"id":"…","status":"done","format":"srt","transcript":"1\n00:00:01,000 --> …"}
# on failure:     {"id":"…","status":"failed","error":"…"}
```

#### Examples

```bash
# Start the server
yap serve

# Start on a custom port with API key auth
yap serve --port 9000 --api-key mysecret

# With auth: pass the key in the header
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
