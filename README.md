# iKit: Apple Ecosystem Agent-Native CLI

`iKit` is a high-performance, native macOS CLI designed specifically for AI Agents. It unifies the management of Apple's core productivity apps.

**Version**: v2.6.0 (Dual-Track + Aggressive Gating)

---

## 核心功能

### 📝 Notes (备忘录)
- **极速同步**: 智能增量同步，支持 ID 隔离
- **安全写入**: 原子化操作，自动同步

### 📋 Tasks & 📅 Calendar
- 基于 `EventKit`，无需启动 App 即可毫秒级读写

### 🖼 Photos
- **Batch OCR**: 批量识别截图文字
- **智能搜索**: 按截图/收藏筛选

### 🎙 Meet (会议助手) [BETA]
- **双轨录制**: 麦克风 + 系统音频独立录制
- **Aggressive Gating**: 自动消除回声，避免重复转录
- **说话人分离**: 自动区分 Local/Remote 说话人
- **本地转写**: 集成 FunASR，完全离线处理
- **Daemon**: 全天候后台录音（每 15 分钟切片）

---

## 快速开始

### 编译与安装
```bash
cd ~/Work/iKit
swift build -c release
cp .build/release/ikit ~/.local/bin/ikit
```

### 基础配置
`~/.config/ikit/config.json`:
```json
{
  "notes_root": "~/Notebooks/AppleNotes",
  "python_path": "/path/to/python",
  "transcribe_script": "/path/to/transcribe.py"
}
```

### 依赖安装
```bash
# Python 依赖（用于转录）
pip install torch torchaudio funasr modelscope librosa scipy soundfile

# Pre-commit hooks（开发）
pip install pre-commit
pre-commit install
```

---

## 开发工具

### Pre-commit Hooks

项目使用 pre-commit 进行代码质量检查。配置文件：`.pre-commit-config.yaml`

首次设置：
```bash
# 安装 pre-commit
pip install pre-commit

# 安装 git hooks
pre-commit install

# 手动运行所有检查
pre-commit run --all-files
```

包含的检查：
- **trailing-whitespace**: 删除行尾空白
- **end-of-file-fixer**: 确保文件以换行符结尾
- **check-yaml**: YAML 语法检查
- **check-added-large-files**: 防止大文件（>1MB）
- **detect-private-key**: 检测私钥泄露
- **swift-format**: Swift 代码格式化（需单独安装：`brew install swift-format`）

跳过检查（紧急情况）：
```bash
git commit --no-verify -m "message"
```

---

## Meet 会议助手使用

### 1. 启动 Daemon
```bash
# 默认模式（麦克风 + 系统音频）
ikit meet daemon ~/recordings

# 只录系统音频（无回声风险）
ikit meet daemon --system-only ~/recordings

# 只录麦克风
ikit meet daemon --mic-only ~/recordings
```

### 2. 输出文件结构
```
~/recordings/
├── 2026-01-12T080000Z_mic.m4a   # 麦克风录音
└── 2026-01-12T080000Z_sys.m4a   # 系统音频录音
```

### 3. 转录（带 Gating）
```bash
# 双轨转录 + 自动回声消除 + 说话人分离
python scripts/transcribe.py \
  ~/recordings/2026-01-12T080000Z_mic.m4a \
  ~/recordings/2026-01-12T080000Z_sys.m4a \
  -o transcript.json

# 输出 JSON：
{
  "sentence_info": [
    {"text": "大家好", "speaker": "Remote", "start": 0, "end": 1000},
    {"text": "请继续", "speaker": "Local", "start": 1500, "end": 2500}
  ]
}
```

---

## Aggressive Gating 原理

### 问题：回声导致重复转录
```
对方说话 → Speaker → 空气 → Mic
                          ↓
                      回声（模糊）
                          ↓
                    ASR 识别两次 ❌
```

### 解决：Aggressive Gating
```
对方说话时：
  System Energy > threshold → Mic 静音

  结果：对方说话只被识别一次 ✅
```

### 参数
- **threshold**: 0.05 (-26dB) - 触发静音的能量阈值
- **margin**: 0.1s (100ms) - 前后扩展时间，彻底消灭残留

---

## 录制模式对比

| 模式 | 适用场景 | 回声风险 |
|------|----------|----------|
| `--system-only` | 会议记录（无麦克风） | 无 |
| `both` (戴耳机) | 需要麦克风输入 | 无 |
| `both` (扬声器) | 需要麦克风 + Gating | Gating 消除 |

---

Copyright © 2026 Kyle Li. All rights reserved.
