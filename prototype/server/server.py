#!/usr/bin/env python3
# server.py — 本地 STT + 可选 LLM 润色
# 对应 Wispr Flow 的云端流式 ASR（wss://api.wisprflow.ai/）与 LLM 格式化层（api.baseten.co）。
#
# 接收 PCM16/单声道音频，返回转写文本。用 faster-whisper 本地推理，零 API key，
# 可完全离线。Listen http://127.0.0.1:8777 。启动：
#   pip install faster-whisper   # 首次会下载模型
#   python server.py

import io
import numpy as np
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from faster_whisper import WhisperModel

MODEL = "small"  # tiny/base/small/medium；需要更多精度时调大
SAMPLE_RATE = 16000  # faster-whisper 用 16k

model = WhisperModel(MODEL, device="cpu")

# 可选：LLM 润色（对应 Wispr 的 "edits as you speak"）。不设置 OPENAI_API_KEY 则跳过。
def polish(raw: str) -> str:
    import os
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        return raw
    try:
        from openai import OpenAI
        r = OpenAI(api_key=key).chat.completions.create(
            model="gpt-4o-mini",
            messages=[{
                "role": "user",
                "content": (
                    "Clean up this spoken transcript into natural written text. "
                    "Remove filler (um, uh), fix repetitions and grammar, add punctuation, "
                    "keep the meaning. Output only the result.\n\n---\n" + raw
                ),
            }],
        )
        return r.choices[0].message.content
    except Exception:
        return raw  # 润色失败则回退到原始转写


def pcm16_to_float32(pcm: bytes) -> np.ndarray:
    a = np.frombuffer(pcm, dtype=np.int16)
    return a.astype(np.float32) / 32768.0


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/transcribe":
            self.send_response(404); self.end_headers(); return
        n = int(self.headers.get("content-length", 0))
        pcm = self.rfile.read(n)
        audio = pcm16_to_float32(pcm)
        if audio.size == 0:
            self._json({"text": ""}); return
        segments, _ = model.transcribe(audio, beam_size=5, sample_rate=SAMPLE_RATE)
        raw = " ".join(s.text.strip() for s in segments).strip()
        result = polish(raw)
        self._json({"text": result, "raw": raw})

    def _json(self, obj):
        import json
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # 静默


if __name__ == "__main__":
    print(f"loading model '{MODEL}'...", flush=True)
    print("STT listening on http://127.0.0.1:8777", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8777), Handler).serve_forever()
