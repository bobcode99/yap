# syntax=docker/dockerfile:1.7
#
# Build slim per-backend images:
#   docker build --target whisper-cpp     -t yap:whisper .
#   docker build --target faster-whisper  -t yap:faster  .
#   docker build --target sherpa-onnx     -t yap:sherpa  .
#   docker build --target all             -t yap:all     .  (default)

# ---- Build yap-server ----
FROM swift:6.1-jammy AS swift-build
WORKDIR /src
COPY Package.swift Package.resolved* ./
COPY Sources ./Sources
RUN swift build -c release --product yap-server
RUN BIN_PATH="$(swift build -c release --product yap-server --show-bin-path)" \
    && mkdir -p /out \
    && cp "$BIN_PATH/yap-server" /out/yap-server \
    && cp -R "$BIN_PATH"/*.resources /out/ 2>/dev/null || true

# ---- Build whisper-cli ----
FROM ubuntu:22.04 AS whisper-build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth=1 https://github.com/ggerganov/whisper.cpp.git .
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_EXAMPLES=ON \
    && cmake --build build --target whisper-cli -j

# ---- Shared runtime base (no backends) ----
FROM ubuntu:22.04 AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates ffmpeg libgomp1 libcurl4 libxml2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=swift-build /usr/lib/swift /usr/lib/swift
COPY --from=swift-build /out/ /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["yap-server", "--host", "0.0.0.0", "--port", "8080"]

# ---- whisper-cpp only ----
FROM base AS whisper-cpp
COPY --from=whisper-build /src/build/bin/whisper-cli /usr/local/bin/whisper-cli
ENV YAP_WHISPER_MODEL=/models/whisper/ggml-base.bin

# ---- faster-whisper only ----
FROM base AS faster-whisper
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip \
    && pip3 install --no-cache-dir faster-whisper \
    && rm -rf /var/lib/apt/lists/*
ENV YAP_FASTER_WHISPER_MODEL=base

# ---- sherpa-onnx only ----
FROM base AS sherpa-onnx
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip \
    && pip3 install --no-cache-dir sherpa-onnx \
    && rm -rf /var/lib/apt/lists/*
ENV YAP_SHERPA_ONNX_SENSE_VOICE_MODEL=/models/sherpa/model.onnx \
    YAP_SHERPA_ONNX_TOKENS=/models/sherpa/tokens.txt

# ---- All three backends (default) ----
FROM base AS all
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip \
    && pip3 install --no-cache-dir faster-whisper sherpa-onnx \
    && rm -rf /var/lib/apt/lists/*
COPY --from=whisper-build /src/build/bin/whisper-cli /usr/local/bin/whisper-cli
ENV YAP_WHISPER_MODEL=/models/whisper/ggml-base.bin \
    YAP_FASTER_WHISPER_MODEL=base \
    YAP_SHERPA_ONNX_SENSE_VOICE_MODEL=/models/sherpa/model.onnx \
    YAP_SHERPA_ONNX_TOKENS=/models/sherpa/tokens.txt
