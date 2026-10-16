# 最小「语音输入法」原型（复刻 Wispr Flow 核心闭环）

比照逆向分析得到的 Wispr Flow 链路，做一个最小可跑的闭环：
**按住说话 → 采麦克风(PCM) → 本地 Whisper 转写 → （可选 LLM 润色） → 插入当前光标应用。**

目录结构：

```
prototype/
├── README.md                 (本文件)
├── capture/                  (Electron 采集层)
│   └── capture.js
├── server/                   (STT + 可选润色 服务端)
│   └── server.py
├── insert/                   (macOS 原生插入层, Swift)
│   ├── Package.swift
│   └── Sources/dictate_insert/main.swift
└── run.sh                    (一键串联脚本)
```

## 依赖

- Node (Electron) —— 采集层；也可直接用浏览器 `getUserMedia` 验证
- Python + `faster-whisper`（本地 STT）
- Swift toolchain（`swift build`）—— 插入层
- Xcode Command Line Tools

## 运行

```bash
# 1. 转写服务
cd server && pip install faster-whisper && python server.py

# 2. 构建插入工具（只需一次）
cd insert && swift build

# 3. 一键演示
./run.sh "hello world"
```

## 权限

- 系统设置 → 隐私与安全性 → **辅助功能**（勾选你的 dictation app / 终端 —— 这是插入其它应用的必要条件）
- 系统设置 → 隐私与安全性 → **麦克风**
- 没有「辅助功能」权限时，`AXIsProcessTrusted()` 返回 false，插入会失败。

## 与 Wispr Flow 的实现对照

| 本原型 | Wispr Flow 中的对应 |
|---|---|
| `capture.js` 的 `getUserMedia` + AudioContext | renderer `hub/index.js` 的 `getUserMedia` + `AudioContext` + Opus worker |
| `server.py` faster-whisper | `wss://api.wisprflow.ai/` 云端流式 ASR |
| `server.py` 可选 `polish()` | `api.baseten.co` 的 LLM 格式化模型 |
| `insert/main.swift` 的 AXValue + 剪贴板回退 | Swift 助手 `helper.paste_execute`（`AXValue` / `NSPasteboard` + Cmd+V）|
