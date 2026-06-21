# Shell Agent — 终端里的 AI 编程助手 🧠⚡

> **一句话：一个纯 Bash 脚本，让你在终端里拥有一个会读代码、会写代码、会跑命令的 AI 助手。**

纯粹发癫让agent写的一个东西

Shell Agent 是一个轻量级的 AI Agent 框架。它只有一个文件——`agent.sh`，却能将任何支持 Function Calling 的大模型（OpenAI、Claude、本地 LLM 等）接入你的终端，并且实现了一个agent的雏形

## ✨ 特性亮点

这里本来agent帮忙写了一堆，不过其实也就只有一点：它是一个shell脚本

## 🚀 快速开始

### 1. 下载脚本

下载就行，管你是克隆还是咋整都无所谓

### 2. 运行

有执行权限的话直接
```bash
./agent.sh
```

然后就会引导你输入：
1. **API Base URL** — 例如 `https://api.openai.com/v1`
2. **API Key** — 你的 API 密钥（输入时不可见）
3. **Model** — 选择模型（如果安装了 `fzf`，会弹出交互式选择列表）

或者使用环境变量指定也没问题

### 3. 开始使用

就像是使用agent一样用它就行

## ⚙️ 环境变量

所有配置也可以通过环境变量传入，避免交互式输入：

```bash
export API_BASE="https://api.openai.com/v1"
export API_KEY="sk-xxxxx"
./agent.sh
# 然后选择模型或直接传入：
# 如果有 fzf，会自动拉取模型列表供选择
```

写成一行也无所谓

## 🔧 自定义权限规则

编辑 `agent.sh` 开头的数组即可：

```bash
# 禁止写入 /home 目录
WRITE_BLACKLIST+=('^/home/')

# 允许 docker 命令
BASH_WHITELIST+=('^docker\b')
```

## 🧠 它是如何工作的？

```
你输入任务 → 构建 System Prompt（含 AGENTS.md） → 调用 LLM API
                                                      ↓
                     AI 返回思考 + 工具调用 ← 循环 ← 执行工具并返回结果
                                                      ↓
                                              得到最终答案 → 输出
```

底层原理不复杂：
1. 用 **Function Calling** 标准格式定义了四个工具（`read` / `write` / `bash` / `ask`）
2. 通过 `curl` 调用兼容 OpenAI 格式的 API
3. 在每次工具调用前后插入**权限检查钩子**（黑/白名单 + 交互确认）
4. 多轮循环直到 AI 给出最终回答

## 📦 依赖

| 工具 | 必选 | 用途 |
|------|------|------|
| `bash` 4+ | ✅ | 运行脚本 |
| `curl` | ✅ | 调用 LLM API |
| `jq` | ✅ | 处理 JSON |
| `glow` | ❌ 可选 | 美化 Markdown 输出 |
| `fzf` | ❌ 可选 | 交互式模型选择 |

## 🆚 与其他方案对比

| 特性 | Shell Agent | Open Interpreter | Aider | Codex CLI |
|------|:-----------:|:----------------:|:-----:|:---------:|
| 文件数量 | **1 个** | 数百个 | 数百个 | 数百个 |
| 依赖 | **curl + jq** | Python 生态 | Python 生态 | Node.js 生态 |
| 启动时间 | **毫秒级** | 秒级 | 秒级 | 秒级 |


