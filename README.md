# agent-sh — 终端里的 AI 编程助手 🧠⚡

> 一个纯 Bash 脚本，零依赖，让你在终端里拥有会读代码、写代码、跑命令的 AI 助手。

## 特性

- **单文件** — 仅 `agent.sh`（1570 行），除 `bash`/`curl`/`jq` 外零依赖
- **Function Calling** — 对接任意兼容 OpenAI 格式的 LLM（OpenAI、Claude、本地 LLM 等）
- **安全沙箱** — 文件/命令黑白名单 + 交互确认，危险操作先问人
- **Patch 模式** — `edit` 工具支持精确替换和 unified diff 双模式
- **多工具链式** — `read` / `edit` / `bash` / `ask` / `load_skill`，AI 自主循环调用
- **Skill 系统** — 加载技能包扩展能力（支持 OpenCode 目录 + 项目本地 `skills/`）
- **上下文感知** — 自动注入 `AGENTS.md` / `CLAUDE.md`，AI 了解你的代码库
- **会话持久化** — 自动保存对话到 `sessions/`，支持恢复
- **毫秒级启动** — 纯 Bash，无 Python/Node.js 运行时

## 🚀 快速开始

```bash
chmod +x agent.sh
./agent.sh
```

首次运行引导配置 API Base URL、API Key 和 Model。也可直接用环境变量免交互：

```bash
export API_BASE="https://api.openai.com/v1"
export API_KEY="sk-xxxxx"
export MODEL="gpt-4o-mini"
./agent.sh
```

## 工具

| 工具 | 功能 |
|------|------|
| `read` | 读文件，支持分页，大文件自动截断 |
| `edit` | 编辑文件（精确替换 / unified diff 双模式） |
| `bash` | 执行命令，有超时和黑白名单保护 |
| `ask` | 向用户交互提问 |
| `load_skill` | 加载技能包 |

## 🔒 安全

编辑 `agent.sh` 顶部配置自定义黑白名单：

```bash
WRITE_BLACKLIST+=('^/home/')    # 禁止写入的路径
BASH_WHITELIST+=('^docker\b')   # 允许的命令
```

默认拦截高危路径（`/etc`、`/root` 等）和危险命令（如删除、杀进程等），越界操作均需用户确认。

## 📦 依赖

**必选：** `bash` 4+、`curl`、`jq`  
**可选：** `glow`（美化输出）、`fzf`（交互式模型选择）

## 📝 命令

| 命令 | 说明 |
|------|------|
| `/init [path]` | 创建 `AGENTS.md` 项目指令模板 |