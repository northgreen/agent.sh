# agent-sh — 终端里的 AI 编程助手 🧠⚡

> **一个纯 Bash 脚本，零依赖，让你在终端里拥有一个会读代码、会写代码、会跑命令的 AI 助手。**

## ✨ 特性

| 特性 | 说明 |
|------|------|
| **单文件** | 只有一个 `agent.sh`（1078 行），除 `bash/curl/jq` 外零依赖 |
| **Function Calling** | 对接任意兼容 OpenAI 格式的 LLM（OpenAI、Claude、本地 LLM 等） |
| **安全沙箱** | 文件/命令黑白名单 + 交互确认，危险操作先问人 |
| **Patch 模式** | `write` 工具支持 unified diff 增量修改，省时省 token |
| **多工具链式** | `read` / `write` / `bash` / `ask` / `load_skill`，AI 自主循环调用直到完成 |
| **Skill 系统** | 通过 `load_skill` 加载技能包，扩展 AI 能力（支持 OpenCode skills 目录 + 项目本地 `skills/`） |
| **上下文感知** | 自动注入 `AGENTS.md` 和项目结构，AI 了解你的代码库 |
| **毫秒级启动** | 纯 Bash 实现，无 Python/Node.js 运行时 |

## 🚀 快速开始

### 1. 运行

```bash
chmod +x agent.sh
./agent.sh
```

首次运行会引导你输入：

1. **API Base URL** — 如 `https://api.openai.com/v1`
2. **API Key** — 输入时不可见
3. **Model** — 选择模型（有 `fzf` 会弹出交互式列表）

### 2. 用环境变量免交互

```bash
export API_BASE="https://api.openai.com/v1"
export API_KEY="sk-xxxxx"
./agent.sh
```

### 3. 开始对话

直接在终端描述你的任务，AI 会自主决定调用工具：

| 工具 | 功能 |
|------|------|
| 🔍 `read` | 读文件，支持分页偏移（大文件自动截断 200 行 / 10KB） |
| ✏️ `write` | 写文件，支持全文覆盖或 `patch` 增量修改 |
| ⚡ `bash` | 执行 shell 命令，有超时保护（默认 30s） |
| 🗣️ `ask` | 交互式向用户确认 |
| 🧰 `load_skill` | 加载专业技能包 |

## 🔒 安全机制

### 权限黑白名单

编辑 `agent.sh` 顶部的配置数组即可自定义：

```bash
# 禁止写入的路径（正则）
WRITE_BLACKLIST+=('^/home/')

# 允许 docker 命令
BASH_WHITELIST+=('^docker\b')
```

**默认安全策略：**

| 维度 | 黑名单（拦截） | 白名单（放行） | 越界处理 |
|------|---------------|---------------|---------|
| **文件写入** | `/etc`, `/bin`, `/boot`, `/dev`, `/proc`, `/sys`, `/root`, `/usr/local/bin`, `/var/run` | `/tmp`, `/var/log`, `/var/tmp` | 拦截 + 用户确认 |
| **命令执行** | `rm`, `dd`, `mkfs`, `kill`, `pkill`, `killall` 等 | `ls`, `pwd`, `echo`, `cat`, `grep`, `wc`, `find`, `head`, `tail`, `sort`, `uniq` | 拦截 + 用户确认 |

### 工具级防护

- `read` — 自动截断大文件，分页读取
- `write` — 路径黑名单 + `patch` 增量模式
- `bash` — 命令黑名单 + 超时保护 + 临时文件自动清理

## 📦 依赖

| 工具 | 必选 | 用途 |
|------|------|------|
| `bash` 4+ | ✅ | 运行脚本 |
| `curl` | ✅ | 调用 LLM API |
| `jq` | ✅ | 处理 JSON |
| `glow` | ❌ | 美化 Markdown 输出 |
| `fzf` | ❌ | 交互式模型选择 |

## 🧠 工作原理

```
你输入任务 → 构建 System Prompt（含 AGENTS.md） → 调用 LLM API
                                                    ↓
                     AI 返回思考 + 工具调用 ← 循环 ← 执行工具并返回结果
                                                    ↓
                                            得到最终答案 → 输出
```

1. 用 **Function Calling** 标准格式定义工具（`read` / `write` / `bash` / `ask` / `load_skill`）
2. 通过 `curl` 调用兼容 OpenAI 格式的 API
3. 每次工具执行前经过 **权限检查**（黑白名单 + 交互确认）
4. 多轮循环直到 AI 给出最终回答

## 📝 命令

| 命令 | 说明 |
|------|------|
| `/init [path]` | 在指定目录（或当前目录）创建 `AGENTS.md` 项目指令模板 |

## 📊 对比

| 特性 | agent-sh | Open Interpreter | Aider | Codex CLI |
|------|:--------:|:----------------:|:-----:|:---------:|
| 文件数量 | **1** | 数百个 | 数百个 | 数百个 |
| 依赖 | **curl + jq** | Python | Python | Node.js |
| 启动时间 | **毫秒级** | 秒级 | 秒级 | 秒级 |

## 📝 License

MIT