#!/bin/bash
# One-time setup for Murmur's Whisper engine (about 1.6 GB including the model).
set -euo pipefail
V="$HOME/Library/Application Support/Murmur/whisper-venv"
python3 -m venv "$V"
"$V/bin/pip" install -q --upgrade pip mlx-whisper
"$V/bin/python" -c "import mlx_whisper, numpy as np; mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo='mlx-community/whisper-large-v3-turbo')"
echo "Whisper ready."
