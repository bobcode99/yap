swift run yap transcribe /Users/junnianlo/github-things/whisper.cpp/samples/jfk.mp3 --backend whisper.cpp --whisper-cpp-binary ~/github-things/whisper.cpp/build/bin/whisper-cli --whisper-cpp-model ~/github-things/whisper.cpp/models/ggml-base.en.bin  --srt -o jfk.srt


swift run yap serve --host 0.0.0.0 --log-level debug --backend whisper.cpp --whisper-cpp-binary ~/github-things/whisper.cpp/build/bin/whisper-cli --whisper-cpp-model ~/github-things/whisper.cpp/models/ggml-base.en.bin