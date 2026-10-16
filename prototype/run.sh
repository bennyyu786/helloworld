#!/usr/bin/env bash
# run.sh — 一键演示：把给定/读到的麦克风音频转写后插入当前光标
# 用法:
#   ./run.sh "可以手动输入的文字"
#   ./run.sh --file audio.wav        # 用一段 WAV 文件转写（离线验证 STT 用）
# 说明: 完整「按住说话→插入」闭环需 Electron 采集层 + 麦克风权限，此脚本先验证
#       STT+插入两段（用 WAV 或手动文本代替麦克风）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ "$1" = "--file" ]; then
  # 用一段 WAV 测转写（16k 单声道），需要 sox 或 ffmpeg 转成 PCM/16bit 传给 server
  WAV="$2"
  echo "[1/3] 转写 $WAV ..."
  # 转成 16kHz 单声道 16bit PCM
  TMP="$(mktemp)"
  ffmpeg -y -i "$WAV" -ac 1 -ar 16000 -f s16le "$TMP" 2>/dev/null || sox "$WAV" -r 16000 -c 1 -b 16 -e signed-integer "$TMP"
  TEXT="$(curl -s -X POST --data-binary @"$TMP" http://127.0.0.1:8777/transcribe | python3 -c 'import sys,json;print(json.load(sys.stdin)["text"])')"
  rm -f "$TMP"
  echo "   转写结果: $TEXT"
elif [ "$1" != "" ]; then
  TEXT="$1"
  echo "[1/3] 使用给定文本: $TEXT"
  shift
else
  echo "用法: $0 \"<text>\" 或 $0 --file <wav>" >&2; exit 1
fi

echo "[2/3] 插入到当前光标应用 (辅助功能) ..."
BIN="$ROOT/insert/.build/debug/dictate_insert"
"$BIN" --text "$TEXT"

echo "[3/3] 完成 ✓"
