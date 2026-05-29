#!/usr/bin/env python3

import argparse
import json
from faster_whisper import WhisperModel


def fmt_time(t, sep):
    ms = int(round((t - int(t)) * 1000))
    s = int(t) % 60
    m = (int(t) // 60) % 60
    h = int(t) // 3600
    return "%02d:%02d:%02d%s%03d" % (h, m, s, sep, ms)


def render(payload, fmt):
    if fmt == "txt":
        return payload["text"]
    if fmt == "json":
        return json.dumps(payload, ensure_ascii=False)
    if fmt == "vtt":
        cues = []
        for i, seg in enumerate(payload["segments"], start=1):
            cues.append("%d\n%s --> %s\n%s" % (
                i, fmt_time(seg["start"], "."), fmt_time(seg["end"], "."), seg["text"]))
        return "WEBVTT\n\n" + "\n\n".join(cues)
    # default: srt
    cues = []
    for i, seg in enumerate(payload["segments"], start=1):
        cues.append("%d\n%s --> %s\n%s" % (
            i, fmt_time(seg["start"], ","), fmt_time(seg["end"], ","), seg["text"]))
    return "\n\n".join(cues)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-path", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--language")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--compute-type", default="default")
    parser.add_argument("--max-length", type=int, default=40)
    parser.add_argument("--word-timestamps", action="store_true")
    parser.add_argument("--format", default="srt", choices=["txt", "srt", "vtt", "json"])
    args = parser.parse_args()

    model = WhisperModel(args.model, device=args.device, compute_type=args.compute_type)
    segments, info = model.transcribe(
        args.audio_path,
        language=args.language,
        word_timestamps=args.word_timestamps,
    )
    materialized = list(segments)

    payload = {
        "backend": "faster-whisper",
        "model": args.model,
        "language": getattr(info, "language", None),
        "duration": getattr(info, "duration", None),
        "text": "".join(segment.text for segment in materialized).strip(),
        "segments": [],
    }

    for index, segment in enumerate(materialized, start=1):
        item = {
            "id": index,
            "start": segment.start,
            "end": segment.end,
            "text": segment.text.strip(),
        }
        if args.word_timestamps and getattr(segment, "words", None):
            item["words"] = [
                {"word": word.word, "start": word.start, "end": word.end}
                for word in segment.words
            ]
        payload["segments"].append(item)

    print(render(payload, args.format))


if __name__ == "__main__":
    main()
