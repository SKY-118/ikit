# iKit: Your On-Device Meeting Assistant

**iKit** 是一款专门为 macOS 设计的、全本地运行的会议助理工具。它能够自动录制会议、区分说话人、识别屏幕内容，并利用本地 LLM 生成精简的会议纪要。

---

## ✨ 核心特性

*   **🔒 隐私至上**：所有音频转录 (ASR) 和大模型总结 (LLM) 均在本地完成，无需上传任何数据到云端。
*   **🎙️ 原生录音 (SCK)**：基于 `ScreenCaptureKit`，无需安装虚拟声卡即可录制 Teams、腾讯会议等 App 的声音。
*   **🗣️ 说话人识别**：内置阿里 FunASR (Paraformer + Cam++)，精准区分不同发言人。
*   **👁️ 多模态对齐**：录音时自动对会议窗口抽帧并运行 OCR，利用视觉信息辅助识别发言人真实姓名。
*   **♾️ 全天候录制**：支持循环分片录制模式，打造个人的“数字记忆”。

---

## 🛠️ 环境准备

### 1. 系统要求
*   macOS 13.0+ (建议使用 M1/M2/M3 系列芯片以获得 GPU 加速)。
*   **权限**：在 `系统设置 -> 隐私与安全性` 中授予终端 **“屏幕录制”** 权限。

### 2. 本地 LLM
*   安装 [Ollama](https://ollama.com/)。
*   拉取模型：`ollama pull qwen3:4b`。

### 3. Python ASR 环境
```bash
python3 -m venv tmp/funasr_env
source tmp/funasr_env/bin/activate
pip install torch torchaudio funasr modelscope
```

---

## 🚀 快速开始

### 安装 iKit
```bash
make install
```

### 常用命令

#### 1. 录制并自动转录总结
```bash
# 录制 Teams 声音 10 分钟
ikit meet record meeting.m4a --duration 600 "Microsoft Teams"

# 运行全天候自动监控脚本
./scripts/always_on.sh
```

#### 2. 处理已有的录音
```bash
# 转录音频 (生成 .json)
ikit meet transcribe meeting.m4a

# 生成纪要 (JSON -> Markdown)
ikit meet process meeting.json ~/Notebooks/journal/
```

---

## 📅 项目路线图 (Roadmap)

### Phase 1: MVP (当前进度) ✅
- [x] 基于 ScreenCaptureKit 的原生录音。
- [x] 集成 FunASR + GPU (MPS) 加速。
- [x] 基于 OCR 的说话人真实姓名推断。
- [x] 全天候循环录制脚本。

### Phase 2: 体验优化 (P1)
- [ ] **去 Python 化**：将 ASR 引擎迁移至 `Sherpa-ONNX`，彻底消除 Python 环境依赖。
- [ ] **AEC 增强**：在 `AVAudioEngine` 中开启 `voiceProcessingIO`，支持外放场景下的回声消除。
- [ ] **UI 托盘**：增加菜单栏小图标，实时显示录音状态和 ASR 进度。

### Phase 3: 智能大脑 (P2)
- [ ] **向量检索**：集成 SQLite-Vector，支持对历史会议纪要进行语义搜索。
- [ ] **RAG 增强**：总结会议时自动关联之前的相关背景文档。

---
*Built with ❤️ for Privacy and Efficiency.*