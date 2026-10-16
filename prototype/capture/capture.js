// capture.js — Electron 渲染进程：按住说话 → 采麦克风 PCM → 发给转写服务
// 对应 Wispr Flow renderer 的 getUserMedia + AudioContext 层。
//
// 说明：这是示意性的可运行骨架。真实 demo 建议在 Electron 的 BrowserWindow
// 里跑（浏览器需 HTTPS 或 localhost 才允许 getUserMedia），或用 body 注入。

const startCapture = async ({ onPcm }) => {
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: {
      echoCancellation: true,
      noiseSuppression: true,
      sampleRate: 48000,
      channelCount: 1,
    },
  });
  const ctx = new AudioContext({ sampleRate: 48000 });
  const src = ctx.createMediaStreamSource(stream);
  const proc = ctx.createScriptProcessor(4096, 1, 1);

  // PCM 16-bit little-endian，单声道
  proc.onaudioprocess = (e) => {
    const f32 = e.inputBuffer.getChannelData(0);
    const pcm = new Int16Array(f32.length);
    for (let i = 0; i < f32.length; i++) {
      pcm[i] = Math.max(-1, Math.min(1, f32[i])) * 0x7fff;
    }
    onPcm?.(new Uint8Array(pcm.buffer));
  };

  src.connect(proc);
  proc.connect(ctx.destination); // ScriptProcessor 需要连到 destination 才会触发
  return { stream, stop: async () => { proc.disconnect(); src.disconnect(); stream.getTracks().forEach(t => t.stop()); } };
};

// 直接把 PCM 流式 POST 给本地转写服务（见 server/server.py）
const sendToServer = async (pcmBytes) => {
  await fetch('http://127.0.0.1:8777/transcribe', {
    method: 'POST',
    headers: { 'content-type': 'application/octet-stream' },
    body: pcmBytes,
  });
};

export { startCapture, sendToServer };
