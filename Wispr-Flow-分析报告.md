# Wispr Flow 逆向分析报告

> 分析对象：`/Applications/Wispr Flow.app`（版本 1.6.1147，`com.electron.wispr-flow`）
> 分析日期：2026-10-15
> 分析工具：REA（Electron / asar / Mach-O / SQLite / codesign 检查）+ 应用运行时数据目录
> 背景来源：`https://www.wisprflow.com/`（官网主页抓取）

---

## 一、它是什么（可直接证明的事实）

| 属性 | 值 | 证据来源 |
|---|---|---|
| 类型 | Electron 桌面应用（macOS） | `Info.plist`：`CFBundleIdentifier = com.electron.wispr-flow`，`NSPrincipalClass = AtomApplication` |
| 版本 | 1.6.1147 | `CFBundleShortVersionString` / `CFBundleVersion` |
| 签名 | Developer ID Application: **Wispr AI INC**（Team `C9VQZ78H85`），硬运行时（hardened runtime），含 `audio-input` entitlement | `codesign -d` |
| 架构 | arm64（Apple Silicon） | Mach-O 头 |
| app.asar | 134 MB，166 个 JS 文件，3447 个 webpack 模块 | `analyze_javascript_application` |
| 运行时数据 | `~/Library/Application Support/Wispr Flow/flow.sqlite`（约 2.4 MB）+ `config.json` + `session.json` | 遍历 user data 目录 |

**关键结论：这不是一个纯 Electron 应用，而是「Electron 外壳 + Swift 原生辅助应用」的混合体。**

应用内嵌了一个用 Swift 写的原生帮助程序（`Resources/swift-helper-app-dist/Wispr Flow.app`，版本同为 1.6.1147）和一个 macOS 权限引导助手（`Helpers/FlowPermissionGuide.app`）。**这个 Swift 助手是「向其他应用插入文本」能力的核心**，也是官方 FAQ 里「无需插件、任意应用可用」如何实现的答案。

### 声明的权限（来自 Info.plist 与签名 entitlement）

- `NSMicrophoneUsageDescription` → 麦克风转写
- `NSAudioCaptureUsageDescription` → 会议录音
- `NSCameraUsageDescription` / `NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription` → 摄像头 / 蓝牙耳机
- `NSAllowsArbitraryLoads = true`（ATS 完全放开）→ 应用内请求可连接任意 host
- 签名 entitlement `com.apple.security.device.audio-input` → 音频输入设备访问
- entitlement `com.apple.security.cs.allow-jit` → Electron/Chromium JS JIT

---

## 二、官网产品描述（背景）

官网把产品定位为 **「voice-to-text dictation & AI notetaker」（语音转文字 + AI 记事本）**。核心卖点：

- **「Don't type, just speak」** — 任意应用里说话即打字，宣称比键盘快 4 倍、220 wpm
- **「Flow edits as you speak」** — 边说边改：自动去 filler（"um"）、纠正、去重复、加标点、格式化
- **「Use it anywhere」** — 无需插件，能打字的地方（Gmail / Slack / iMessage / Notion / 终端 / 代码编辑器 / ChatGPT / Claude / Cursor）都能用
- **「100+ Languages」** — 自动检测语言、多语言切换
- **「Flow learns your vocabulary」** — 学习专有名词 / 公司黑话，或手动添加
- **「Snippets」** — 自定义文本片段，说个快捷键即展开
- **「Make Flow sound like you」** — 不同应用用不同书写风格（正式 / 随意）
- 资质：SOC 2 Type II、ISO 27001、HIPAA；免费版每周 2000 词
- FAQ 明确两段关键背景：
  1. **「Flow types wherever your cursor is」** —— 光标在哪就在哪打字，无需插件
  2. **不建议用 AirPods / 蓝牙耳机转写**，因为它们会压缩音频、漏掉句首（这解释了代码里为何有专门的蓝牙/麦克风占用监控）

---

## 三、语音捕获 → 转写 → 文本插入 的完整链路

这是本次分析的核心。结合 Electron 主进程、renderer、Swift 助手三部分的静态证据，链路如下：

### 1. 触发（hotkey / push-to-talk）
- 主进程用 **`globalShortcut`**（Electron API）注册热键，支持 **push-to-talk**（按住说话）。代码里有 `pushToTalk`、`toggleDictation`、`hotkey`、`recordingState` 等标识。
- 存在一个 AGENT 桥：`agentToolBridge.js` 实现了 MCP / JSON-RPC（协议 `2024-11-05`），暴露一组工具（`wispr-extension-tools`）给 AI agent —— 说明 Wispr Flow 还能被「agent 调用」来执行插入，这是进阶能力。

### 2. 音频捕获（renderer 层）
- renderer 用 **`navigator.mediaDevices.getUserMedia({ audio: … })`** 打开麦克风。`hub/index.js` 中出现 42 处 `getUserMedia`、47 处 `AudioContext`、13 处 `opusEncoder`。
- 用 **`AudioContext`**（采样率由设备决定，常见 24000/48000 Hz）把 PCM 原始音频送入 **`Opus` 编码 worker**：`opusEncoder.worker.js` 与 `incrementalOpusEncoder.worker.js`（两个独立 Web Worker，增量编码）。
- 音频块通过主进程 IPC（`media:meetingMicChunk` / `dictation:*`）交给主进程上传。IPC channel 如 `com.wispr.flowapp`、`media:initialize`、`media:playDictationStartSound`、`media:getUserMediaError`、`media:audioInterruption`、`media:startMeetingMicCapture` 等。
- 监听麦克风占用与蓝牙状态：Swift 助手里有 `SystemMicrophoneHoldersCoreAudioAdapter`、`MicrophoneHoldersMonitor`（检测哪些进程在占麦克风）、`BLEAudioManager`、`AudioInterruptionMonitor`、`GoogleMeetAudioDeviceNotificationObserver`。

### 3. 转写（云端流式 ASR）
- 音频经 **WebSocket** 流式上传到 Wispr 自有 ASR 服务：`wss://api.wisprflow.ai/` 与 `wss://api-east.wisprflow.ai/`（主/备两个区域）。
- 服务端地址是**动态发现的**：启动时请求 `https://inference-info.wisprflow.com/dictation_url.txt`，返回一个指向自建 gRPC 后端的地址（字符串里出现 `*-server-flowgrpcserver-*.modal.direct`，即托管在 Modal 上的自建 gRPC 服务）。这是「不要硬编码单一 server」的设计。
- 另有 REST 端点：`https://api.wisprflow.ai`（主）、`https://api-east.wisprflow.ai`（备）、本地开发 `http://127.0.0.1:8000`。
- **多回退（fallback）**：`History` 表有 `defaultAsrText` / `fallbackAsrText` / `defaultFormattedText` / `fallbackFormattedText` / `calledExternalAsr` / `usedFallbackAsr` 等字段，说明当自建 ASR 失败时会切换到外部 ASR（`openai`、`azure`、`api.openai.com` 等字符串出现）。
- 会议转写走 REST：`/api/v1/meetings/transcribe`。

### 4. 后处理 / 格式化（LLM「格式化」层）
- 官网强调「Flow edits as you speak —— 去 filler、纠正、去重复、加标点、格式化」，这来自 **LLM 格式化模型**，并非靠 ASR 本身。
- 格式化和「润色」（Polish）调用 **`api.baseten.co`**：代码里有 `https://chain-o232k03l.api.baseten.co/environments/production/run_remote`（自建 LLM 推理平台 Baseten）。`Polish` 表 + `personalization-style` + `polish-prompt-name-shortcut-key` + `polish-used-provider` 等字段说明这类后处理是可配置、可换 provider 的。
- 输出经过「格式化」的文本存为 `formattedText`，ASR 原始文本为 `asrText`，客户端再处理后的**最终待粘贴文本**为 `pastedText`（注释直接写明 `pastedText = textToPaste`）。

### 5. 文本插入（Swift 原生层 —— 最关键）
这一步不在 Electron/JS 里，而在内嵌的 Swift 助手 (`swift-helper-app-dist/Wispr Flow.app`)。主进程用 `app.isPackaged ? <resourcesPath>/swift-helper-app-dist/Wispr Flow.app/.../Wispr Flow : <dev path>` 启动它，并通过 IPC（`IPCClient`）调用。

Swift 助手里与插入相关的**真实符号**（来自 `strings` + `nm`）：

- `helper.paste_execute` —— 粘贴执行入口
- `Pasting text with length:` / `Beginning regular pasteText.` / `Beginning pasteText with delimiters.` —— 两种粘贴模式（普通粘贴、带分隔符粘贴，后者用于 IME/CJK/多段场景）
- `AXValue` / `AXValueType` / `AXValueSet` / `AXInsertStyleGroup` / `AXUIElement` / `AXUIElementGetWindow` / `systemAXUIElement` / `AXIsProcessTrusted` / `accessibilityTrusted`
- `ConsentChatPasteboard` / `generalPasteboard` / `NSPasteboard` —— 剪贴板
- 关键日志：**「ConsentChatMessage: direct AXValue set did not stick, falling back to clipboard paste」** 与 **「skipping the clipboard fallback, the pasteboard holds content that cannot be restored」**
- `CGEventFlags` / `CGEventTapOptions` / `CGEventTap` —— 事件 tap（键盘/输入事件监听）
- `KeystrokeTraceRecorder` / `ObservationEndKeystrokeTracker` / `EditedTextManager2` / `ClipboardMonitor` / `DelayedClipboardProvider` / `SecureInputMonitor`
- `cancelPaste` / `Cancelling active paste operation` / `failed-paste-notification` / `failedPasteNotification`
- 另一面：这个 Swift 助手还带会议/媒体能力（`MediaTransport` / `MediaRemoteAdapter` 播放控制、`MeetingTabScanner`、`ConferenceStructureCapture`、`MeetingSpeakerPollingPolicy`、`NowPlayingCache`、`VolumeManager` 等）—— 属于 Notetaker/会议功能，与语音转文字插入不是同一条链路。

#### 插入的两种机制（从字符串与符号推断）
1. **AX（辅助功能 API）直接设值**：通过 `AXUIElement` 定位到光标所在的文本控件，直接设置其值（`AXValue`）或选中插入点后设值。这是最精确的方式（光标在哪就在哪插入），但需要应用已授权辅助功能权限。
2. **剪贴板模拟粘贴（fallback）**：若 AX 设值失败或目标不暴露 AX 值接口，就保存当前剪贴板 → 写入待粘贴文本到 `NSPasteboard`（`generalPasteboard`）→ 向目标应用发送 Cmd+V（键盘事件）→ 恢复原剪贴板。

`SecureInputMonitor` 说明它会检测 macOS 的「安全输入」（Secure Input，密码框）并避开/降级，避免把文本打进密码框。

---


### 完整的「说了 → 出现了」数据流

```
┌─────────────────────────────────────────────────────────────────────┐
│ ① 触发: globalShortcut 热键 / push-to-talk                          │
│    (主进程 Electron，还有 agentToolBridge 的 MCP 工具调用)           │
└───────────────┬─────────────────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────────────┐
│ ② 捕获: renderer 层                                                  │
│    navigator.mediaDevices.getUserMedia({audio})                      │
│    → AudioContext (设备采样率 24k/48k)                               │
│    → Opus 编码 worker (opusEncoder.worker.js / incremental…)         │
│    → 音频块经 IPC (media:meetingMicChunk / dictation:*) 交主进程     │
└───────────────┬─────────────────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────────────┐
│ ③ 转写: 云端流式 ASR (Wispr 自建 / Modal gRPC 后端)                  │
│    wss://api.wisprflow.ai  /  wss://api-east.wisprflow.ai            │
│    端点动态发现: inference-info.wisprflow.com/dictation_url.txt      │
│    失败回退: 外部 ASR (openai/azure 等, calledExternalAsr=true)      │
│    结果: asrText (原始)                                              │
└───────────────┬─────────────────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────────────┐
│ ④ 格式化: LLM 后处理 (Baseten 自建推理)                              │
│    api.baseten.co chain-o232k03l .../run_remote                      │
│    去 filler / 纠正 / 去重复 / 加标点 / 个人风格                     │
│    结果: formattedText → 客户端再处理 → pastedText (= textToPaste)   │
└───────────────┬─────────────────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────────────┐
│ ⑤ 插入: Swift 原生助手 (swift-helper-app-dist/Wispr Flow.app)        │
│    helper.paste_execute                                             │
│      ├─ AXUIElement 定位光标控件 → AXValue 设值 (首选)               │
│      └─ 失败/pasteboard 回退: NSPasteboard + Cmd+V 模拟粘贴          │
│    (KeystrokeTraceRecorder 记录击键 / ClipboardMonitor 恢复剪贴板)    │
└───────────────┬─────────────────────────────────────────────────────┘
                │
                ▼
      出现在你光标所在的任意应用 (Gmail/Slack/Notion/终端/代码编辑器…)
```

---

## 四、哪些能从文件证明 / 哪些是推断 / 哪些仍是未知

### ✅ 能从文件证明（直接证据）

| 事实 | 证据 |
|---|---|
| 它是 Electron 应用（com.electron.wispr-flow），版本 1.6.1147 | `Info.plist` |
| 由 Wispr AI INC 签名，硬运行时，有 audio-input entitlement | `codesign -d --entitlements` |
| 内在是「Electron + Swift 原生助手」混合体，且 Swift 助手版本一致 | `swift-helper-app-dist/` 目录与 `provenance.json`（schema_version 1, helper_version 1.6.1147） |
| 用 Accessibility API 向其他应用插入文本 | Swift 符号 `AXUIElement`、`AXValue`、`AXInsertStyleGroup`、`accessibilityTrusted`、`AXIsProcessTrusted`、字符串 `Beginning regular pasteText.` |
| 有两种插入模式（普通/带分隔符） | `Beginning regular pasteText.` / `Beginning pasteText with delimiters.` 字符串 |
| AX 设值失败会回退到剪贴板粘贴 | `direct AXValue set did not stick, falling back to clipboard paste` |
| 会保存并恢复剪贴板 | `DelayedClipboardProvider`、`ClipboardMonitor`、`skipping the clipboard fallback, the pasteboard holds content that cannot be restored` |
| 用 `globalShortcut` + push-to-talk 触发 | 代码中出现 `globalShortcut`、`pushToTalk`、`toggleDictation` |
| 用 `getUserMedia` + AudioContext + Opus 编码采集麦克风 | `hub/index.js` 42×getUserMedia / 47×AudioContext / 13×opusEncoder；`opusEncoder.worker.js` |
| 音频走云端流式 ASR（WebSocket） | `wss://api.wisprflow.ai/`、`wss://api-east.wisprflow.ai/`、`dictation_url.txt` 动态端点 |
| 存在 LLM「格式化」后处理层 | `api.baseten.co`（`chain-o232k03l` 生产端点）、`Polish` 表、`formattedText`/`desiredFormatted`/`polish-used-provider` 等字段 |
| 落库到 `flow.sqlite` 的 `History` 表，含完整链路字段 | `asrText`、`formattedText`、`pastedText`、`axText`、`axHTML`、`opusChunks`、`editingText`、`language`、`micDevice`、`e2eLatency` 等列 |
| 录制音频（Opus 分块）会持久化 | `opusChunks` JSON 列 + `add_opus_chunks_column` 迁移 |
| 有比重控制/会议 Notetaker 能力 | 内嵌 Swift 助手含 `MeetingTabScanner`、`MediaTransport`、`MediaRemoteAdapter`、`VolumeManager` 等 |

### 🔶 推断（有强证据但没有运行验证）

| 推断 | 依据 | 可信度 |
|---|---|---|
| AX 直接设值是「首选」路径，剪贴板是「回退」 | `AXValue set did not stick` 字符串暗示先试 AX、失败再 fallback | 高 |
| 剪贴板回退通过向目标应用发送 Cmd+V 模拟粘贴 | `CGEventFlags`/`CGEventTap`、`KeystrokeTraceRecorder`、`generalPasteboard` | 中高（具体按键序列未在静态串里确认） |
| 录音用 Opus 编码（而非裸 PCM 上传） | `opusEncoder` worker、`opusChunks` 列、`add_opus_chunks` 迁移 | 高 |
| LLM 格式化用了自建 Baseten 模型服务 | `api.baseten.co chain-o232k03l` 端点 + 官网「edits as you speak」 | 高 |
| 主进程通过 IPC 把音频/文本给 Swift 助手 | Electron 主进程 + `IPCClient` + `com.wispr.flowapp` channel | 中高 |
| 「格式化」的质量来自 LLM 而非 ASR 模型 | `desiredFormatted`、`formattingDivergenceScore`、`defaultAsrText` vs `defaultFormattedText` 冗余字段 | 中高 |
| 自定义词汇/片段/翻译是客户端+服务端联合完成 | `Dictionary`、`add-to-vocabulary`（`Dictionary` 表、`unique-phrase`、`snippets` 迁移） | 中高 |

### ❓ 仍是未知 / 无法从文件确认

| 未知项 | 原因 |
|---|---|
| **具体 ASR 模型与供应商** | 只看到 `wss://api.wisprflow.ai/` 与动态端点文本；自建模型具体是 Whisper 系还是自研模型、是否用 `whisper`（代码出现 6 次但无配置细节）无法确认；外部 fallback 的具体 provider（OpenAI/Azure 哪一家）也无法从静态代码锁定 |
| **Baseten 上跑的具体模型** | `chain-o232k03l` 是部署标识，具体模型名/参数在代码中不可见（在服务端） |
| **权限引导 / 首次授权流程** | `FlowPermissionGuide.app` 是编译后的 Mach-O，需运行时才知行为 |
| **插入是否真的「光标处」还是「焦点控件」** | 代码里既有 `FocusChangeDetector`/`FocusModeManager`（焦点检测），也有 `AXUIElementGetWindow`；语义需运行验证 |
| **键盘事件注入的精确实现**（CGEventTap 是监听还是发送） | `CGEventFlags`/`CGEventTapOptions` 同时可被用于监听别人键盘（安全输入检测）和发送事件，二者静态无法区分 |
| **免费版 2000 词/周如何计数** | 与编码无关，服务端计费/授权逻辑 |
| **model 的「个人风格」如何训练/存储** | `personalization-style`、`user-voice-preferences` 表存在，但具体向量/文本模板在服务端 |
| **Hopper 反编译 Swift 主函数** | REA 的 Hopper bridge 因 license/loader 对话框超时未完成（provider 侧问题），故采用 `strings`/`nm` 静态符号分析替代 |
| **所有会议 Notetaker 细节** | 属于第二条产品线，超出本次「语音转文字插入」范围 |

---

---

## 五、可构建的小型工作版本（建议原型）

目标：复刻「说一句话 → 自动插入到当前光标所在应用」这一条最小闭环。从上文链路抽取出能独立运行、**不含 Wispr 私有服务**的版本。

### 架构选型

比照 Wispr 的「Electron 外壳 + 原生插入层」结构，但简化到 3 块：

```
┌──────────────┐   ┌──────────────────┐   ┌────────────────────┐
│ 前端/捕获层   │   │ 转写 + 格式化服务  │   │ 原生插入层(macOS)   │
│ Electron     │   │ (自研或 SaaS STT)  │   │ Swift 小工具        │
│ getUserMedia │──▶│ Whisper / Deepgram│──▶│ AXValue / 剪贴板    │
│ → PCM/Opus   │   │ + (可选) LLM 润色  │   │ + Cmd+V 回退        │
└──────────────┘   └──────────────────┘   └────────────────────┘
```

### 最小闭环（MVP，可本地运行）

**捕获层（Electron renderer）**
```js
// main/renderer: 按住说话
const stream = await navigator.mediaDevices.getUserMedia({ audio: {
  echoCancellation: true, noiseSuppression: true, sampleRate: 48000 } });
const ctx = new AudioContext();
const src = ctx.createMediaStreamSource(stream);
// 用 ScriptProcessor/AudioWorklet 收集 PCM chunk，或以 16kHz 单声道重采样后发送 svc
```

**转写层（服务端，Python + faster-whisper，本地即可跑）**
```python
# server.py
from faster_whisper import WhisperModel
model = WhisperModel("small", device="cpu")   # 或 base
def transcribe(audio_bytes):
    segments, info = model.transcribe(audio_bytes, beam_size=5)
    return " ".join(s.text for s in segments)
```
> 若要「去 filler / 加标点 / 纠正」，再叠一层 LLM（见下）。

**插入层（Swift 命令行工具 `dictate_insert`，macOS）**
```swift
import ApplicationServices
import Carbon

// 1) 判断辅助功能权限
if !AXIsProcessTrusted() { print("please grant Accessibility"); exit(1) }

// 2) 方案 A：AXUIElement 直接设值
//    找到焦点应用，取其 AXFocusedUIElement，设 AXValue
// 3) 方案 B（回退）：把文本放入 NSPasteboard，再发 Cmd+V
let pb = NSPasteboard.general
pb.clearContents(); pb.setString(text, forType: .string)
// 发送 Cmd+V
let src = CGEventSource(stateID: .hidSystemState)
let v = CGEvent(keyboardEventSource: src, virtualKey: 9 /*V*/, keyDown: true)
v?.flags = .maskCommand; v?.post(tap: .cghidEventTap)
```
> 注意：`AXIsProcessTrusted` 需要用户在「系统设置 → 隐私与安全性 → 辅助功能」勾选你的应用。这是唯一必须的「系统授权」，与 Wispr 的 `FlowPermissionGuide.app` 同理。

**可选：LLM 润色层（格式化）**
```python
# polish.py —— 对齐 Wispr 的 "edits as you speak"
from openai import OpenAI
client = OpenAI()
def polish(raw):
    r = client.chat.completions.create(
      model="gpt-4o-mini",
      messages=[{"role":"user","content":
        f"Clean up this spoken transcript into written text. Remove filler "
        f"(um, uh), fix repetitions and grammar, add punctuation, keep meaning. "
        f"Output only the result.\n\n---\n{raw}"}])
    return r.choices[0].message.content
```
> 这一步对应 Wispr 的 Baseten「格式化」模型，是最能体现「Flow edits as you speak」的部分。

### 需要的服务（按需、可替换）

| 层 | 可选实现 | 是否必须 | 说明 |
|---|---|---|---|
| STT | `faster-whisper`（本地）/ OpenAI `whisper-1` / Deepgram / AssemblyAI | 必须 | 本地的 faster-whisper 零成本、可完全离线；云 STT 精度更高但要 API key |
| LLM 格式化 | OpenAI / Anthropic / 本地 `llama.cpp` | 可选 | 去掉就只是「逐字转写」，无润色 |
| 音频采集 | `getUserMedia`（Electron/浏览器） | 必须 | 系统麦克风 |
| 系统权限 | macOS「辅助功能」+「麦克风」 | 必须 | 无辅助功能则无法插入其它 App |
| 剪贴板恢复 | 原生（NSPasteboard） | 建议 | 避免破坏用户剪贴板 |
| Notetaker/会议 | 无 | 不需要 | 超出 MVP 范围 |

### 最小复刻的启动方式
1. 起 `python server.py` 监听一个 HTTP/WebSocket 端点接收 PCM/音频。
2. `swift build` 一个 `dictate_insert` 可执行文件，给它 `--text "..."`。
3. Electron 端：按住热键 → 采音频 → 发给 server → 拿回文本 → `exec("./dictate_insert --text ...")`。
4. 在终端、编辑器、Slack 里测试光标处插入。

> 更省事替代：直接用现成开源工具拼装 —— 如 `openai/whisper` + `osascript -e 'tell application "System Events" to keystroke ...'`。但 macOS 的 `osascript keystroke` 打某些应用（如终端、IDE）不可靠，**Swift 的 AXValue 方案更接近 Wispr 真实实现**。

---

## 六、附加观察 / 备注（对分析完整性重要）

- **`ax-inspect*.mjs` 与 `flow.sqlite`**：应用自带一套「AX 插入检查器」开发工具（`ax-inspect.mjs`、`ax-inspect-server.mjs`、`ax-inspect-lib.mjs`，监听 `127.0.0.1`），直接读取 `flow.sqlite` 的 `History` 表 + 若干 JSONL 侧车日志（`paste-formatting-debug.jsonl`、`insertion-verification-debug.jsonl`、`textbox-context-debug.jsonl`、`keystroke` 轨迹等），用于**开发排查插入是否成功**。这印证了文本插入是它的核心功能，且会记录「击键轨迹」来做插入验证。
- **`shouldSaveAxText`**：一个内部开关，控制是否把 AX 树快照（`axText`/`axHTML`）存进数据库（仅本地，不上传）。`axText` 是终端 / 复杂控件的 AX 树序列化，含大量 NUL 字节填充的格子文本。
- **`textboxContents`**：记录「光标所在文本框的内容」，用于上下文（`textbox-context-debug.jsonl` 侧车），做智能处理。
- **Webpack 代码体积**：`index.js` 单个 bundle 达 9.8 MB，混入大量第三方库（asn1、rsa、crypto、undici、grpc 等），业务逻辑与其交织，静态反混淆困难；REA 的语义图分析因单文件超预算/worker 堆限制而部分截断（见 Ev 的 limitations）。
- **隐私声明与代码的对照**：官网称「数据绝不售卖、SOC 2/ISO27001/HIPAA」，但静态代码显示音频（`audio`、`opusChunks`、`builtInAudio` BLOB）会落库并上传云端转写。这类「本地与云端、隐私与功能」的张力是分析这类工具时值得标注的点。

---

## 七、结论

Wispr Flow 的本质是一个「**语音输入法**」：它不在某个 App 内，而是以**系统级旁路**方式工作——用 Electron + 浏览器音频 API 采集麦克风、用 Opus 编码流式上传到自建云端 ASR，再用 LLM 做「边说边改」的格式化，最后通过**内嵌 Swift 原生助手调用 macOS 辅助功能 API（AXValue）或剪贴板 + Cmd+V**，把文本塞进你光标所在的任意应用。

它真正「难」也最值得复刻的，不是转写（有现成 STT），而是**最后一步的「无插件跨应用插入」**：需要辅助功能权限、要处理焦点/光标定位、要应付不暴露 AXValue 的应用（回退到模拟粘贴）、还要保护用户剪贴板。这一层被 Wispr 单独做成了 Swift 原生助手，与 Electron 解耦。

一个自研的简化版，只需「麦克风 → STT → （可选 LLM 润色）→ AXValue/剪贴板插入」四步即可跑通核心闭环。

---

*注：本分析基于应用包的静态检查（asar、Swift 二进制 strings/nm、SQLite schema、codesign）与官网公开文案，未运行应用、未注入、未联网抓取任何用户数据。所有「未知」项均如实标注。*
