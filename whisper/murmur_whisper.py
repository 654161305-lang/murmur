"""Murmur's Whisper helper: keeps the model in memory and transcribes on request.

Protocol (one JSON object per line):
  stdin : {"path": "/tmp/x.f32", "prompt": "optional vocabulary hint"}
          the file holds 16 kHz mono float32 samples
  stdout: {"ready": true} once loaded, then {"text": ..., "language": ...} or {"error": ...}
"""
import contextlib
import json
import re
import sys
import time

import numpy as np
import mlx_whisper
import mlx.core as mx
from mlx_whisper.audio import log_mel_spectrogram, pad_or_trim, N_FRAMES, N_SAMPLES
from mlx_whisper.transcribe import ModelHolder
from mlx.utils import tree_flatten

MODEL = "mlx-community/whisper-large-v3-turbo"
# Whisper's classic outputs on silence or noise.
HALLUCINATIONS = {
    "thank you.", "thanks for watching!", "thank you for watching.", "you",
    "字幕由amara.org社区提供", "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目", "謝謝觀看", "谢谢观看",
}


CJK = r"[\u3400-\u9fff\u3000-\u303f\uff00-\uffef]"


def fix_cjk_punctuation(text):
    """Whisper often emits ASCII punctuation in Chinese; use full-width next to CJK characters."""
    for ascii_p, full in ((",", "，"), ("?", "？"), ("!", "！"), (":", "："), (";", "；")):
        text = re.sub(rf"(?<={CJK})\s*{re.escape(ascii_p)}\s*", full, text)
    return re.sub(rf"(?<={CJK})\.(?=\s|$)", "。", text)


def transcribe(audio, prompt):
    # MLX's standard transcribe path encodes the first window once for language
    # detection and again for decoding. Share only *identical* encoder inputs
    # within this request, keeping segmentation, timestamps and quality retries.
    with contextlib.redirect_stdout(sys.stderr):
        model = ModelHolder.get_model(MODEL, mx.float16)
        encoder = model.encoder
        cached_input = None
        cached_features = None
        reuses = 0

        def encode(mel):
            nonlocal cached_input, cached_features, reuses
            if (cached_input is not None and mel.shape == cached_input.shape
                    and mel.dtype == cached_input.dtype
                    and bool(mx.array_equal(mel, cached_input).item())):
                reuses += 1
                return cached_features
            cached_input = mel
            cached_features = encoder(mel)
            return cached_features

        # The helper processes requests serially. Always restore the encoder,
        # including on failure; cached audio never survives into another request.
        model.encoder = encode
        try:
            # Use the same first-window padding as transcription, so language
            # detection and decoding can share its encoder output exactly.
            mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
            content_frames = mel.shape[-2] - N_FRAMES
            first_window = pad_or_trim(mel[:min(content_frames, N_FRAMES)], N_FRAMES, axis=-2).astype(mx.float16)
            features = encode(first_window[None])
            _, probabilities = model.detect_language(features[0])
            language = max(probabilities, key=probabilities.get)
            result = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=MODEL,
                initial_prompt=prompt,
                condition_on_previous_text=False,
                language=language,
                verbose=None,
            )
            result["mode"] = f"shared-encoder; reused={reuses}"
            return result
        finally:
            model.encoder = encoder


def warmup():
    """Read model weights on the GPU without another full recognition pass.

    Reductions touch every weight page after idle/sleep; the scalar results are
    discarded. Keeping this light avoids queuing a full decode before short speech.
    """
    with contextlib.redirect_stdout(sys.stderr):
        model = ModelHolder.get_model(MODEL, mx.float16)
        mx.eval([mx.sum(weight) for _, weight in tree_flatten(model.parameters())])


def serve():
    transcribe(np.zeros(16000, dtype=np.float32), None)  # load + warm up
    print(json.dumps({"ready": True}), flush=True)

    for line in sys.stdin:
        started = time.monotonic()
        is_warmup = False
        try:
            req = json.loads(line)
            is_warmup = req.get("warmup") is True
            if is_warmup:
                warmup()
                out = {"warmed": True}
            else:
                audio = np.fromfile(req["path"], dtype=np.float32)
            if is_warmup:
                pass
            elif audio.size < 16000 * 0.3 or float(np.abs(audio).max()) < 0.01:
                out = {"text": "", "language": None}
            else:
                r = transcribe(audio, req.get("prompt") or None)
                text = r["text"].strip()
                if text.lower() in HALLUCINATIONS:
                    text = ""
                out = {"text": fix_cjk_punctuation(text), "language": r.get("language"),
                       "mode": r.get("mode", "standard")}
        except Exception as e:  # keep serving after a bad request
            out = {"error": str(e)}
            if is_warmup:
                out["warmed"] = False
        out["seconds"] = round(time.monotonic() - started, 3)
        print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    serve()
