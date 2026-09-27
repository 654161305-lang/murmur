# Murmur: voice dictation for macOS

Hold a key, speak, and release. Clean text appears wherever your cursor is.

## Use
- **Hold Right ⌘ Command** while you talk, then let go to paste.
- **Tap it once** for hands-free mode, then tap again to finish.
- **Esc** cancels.
- Menu-bar icon (〰): language, hotkey, Claude cleanup, personal dictionary, recent dictations, launch at login.

## How it works
1. **Whisper** (large-v3-turbo, running locally with MLX) transcribes and detects the language automatically, including mixed 中文 + English. Apple's recognizer runs alongside as a backup, or on its own if you choose it under Speech Engine.
2. Filler words (um/uh/嗯/呃) are stripped and your dictionary rewrites are applied.
3. If a Claude API key is set, Claude polishes the text: self-corrections, punctuation, lists, your vocabulary. If that call fails, it falls back to the basic cleanup.
4. It pastes with ⌘V and restores your previous clipboard.

## Response speed
- After at least 60 seconds of inactivity, pressing the recording key prewarms the model while you speak. It does not run periodically when idle. Recognition still uses the same full recording and model; very short utterances may still wait for the prewarm to finish.
- Language detection and transcription reuse identical audio encoder results within each recording, using the same large-v3-turbo model. The original segmentation and recognition quality checks are preserved, including for longer recordings. The temporary cache is discarded after every request.
- The overlay distinguishes **Transcribing…** from **Polishing…**.
- Optional Claude cleanup defaults to Haiku 4.5 unless you already selected a model. It waits at most 3 seconds, then pastes the complete basic-cleanup text. Late responses cannot paste a second time.
- Status logs include transcription, cleanup, and time-to-paste durations, without recording dictated text.

## Build

Requires an Apple Silicon Mac running macOS 14 or later, Python 3, and the Xcode Command Line Tools. From the repository folder:

```sh
./setup-whisper.sh  # one-time local Python environment and model download (~1.6 GB)
./build.sh
open ~/Applications/Murmur.app
```

The build script installs the app in `~/Applications` and signs it. If a local **Murmur Local Signing** certificate is available, it uses that stable identity; otherwise it uses ad-hoc signing, which may require you to grant macOS permissions again after rebuilding. On first launch, grant Microphone, Speech Recognition, Accessibility, and Input Monitoring access when macOS asks. The app lives in the menu bar.

Speech recognition runs locally. Optional Claude cleanup sends the dictated text to Anthropic only when enabled with your own API key. The key is stored in macOS Keychain. Recent dictations, your personal dictionary, and the status log stay on your Mac under `~/Library/Application Support/Murmur` or app settings; none belong in this repository.

For development checks, run `swiftc -typecheck -swift-version 5 Sources/*.swift` and `python3 Tests/test_whisper.py` after setting up Whisper.

## Files
- `Sources/AppDelegate.swift`: hotkey, menu, record → clean → paste flow
- `Sources/Dictation.swift`: microphone and speech recognition
- `Sources/Cleanup.swift`: filler removal and the Claude polish call
- `Sources/Overlay.swift`: floating waveform pill
- `Sources/Support.swift`: settings, Keychain, dictionary, paste
- `Sources/Whisper.swift` + `whisper/murmur_whisper.py`: Whisper helper process
- Dictionary: `~/Library/Application Support/Murmur/dictionary.txt`
