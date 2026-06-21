#!/bin/bash
set -euo pipefail

# ====================== 权限配置（黑白名单） ======================
# 写入文件路径的黑名单（正则）
WRITE_BLACKLIST=(
    '^/etc/'
    '^/bin/'
    '^/boot/'
    '^/dev/'
    '^/proc/'
    '^/sys/'
    '^/root/'
    '^/sbin/'
    '^/usr/local/bin/'
    '^/var/run/'
)
# 写入文件路径的白名单（正则）
WRITE_WHITELIST=(
    '^/tmp/'
    '^/var/log/'
    '^/var/tmp/'
)

# Bash 命令的黑名单（正则，匹配整个命令字符串）
BASH_BLACKLIST=(
    'rm'
    'dd'
    'mkfs'
    ':\(\)\{'
    '> /dev/sd'
    'chmod 777 /'
    'chown -R /'
    'kill\b'
)
# Bash 命令的白名单（正则，匹配整个命令字符串）
BASH_WHITELIST=(
    '^ls\b'
    '^pwd\b'
    '^echo\b'
    '^cat\b'
    '^grep\b'
    '^wc\b'
    '^find\b'
    '^head\b'
    '^tail\b'
    '^sort\b'
    '^uniq\b'
)

# ====================== 工具函数 ======================
read_file() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path" 2>/dev/null || echo "Error: cannot read file"
    else
        echo "Error: file not found"
    fi
}

write_file() {
    local path="$1"
    local content="$2"

    # ---------- 权限检查（黑白名单） ----------
    # 黑名单检查
    for pattern in "${WRITE_BLACKLIST[@]}"; do
        if [[ "$path" =~ $pattern ]]; then
            echo "❌ Write denied: path matches blacklist pattern '$pattern'." >&2
            return 1
        fi
    done
    # 白名单检查
    local allowed=0
    for pattern in "${WRITE_WHITELIST[@]}"; do
        if [[ "$path" =~ $pattern ]]; then
            allowed=1
            break
        fi
    done
    # 若既非黑名单也非白名单，询问用户
    if [ $allowed -eq 0 ]; then
        echo "⚠️  Write to '$path' is not in whitelist." >&2
        read -p "Allow write? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Write denied by user."
            return 1
        fi
    fi

    # 执行写入
    mkdir -p "$(dirname "$path")" 2>/dev/null
    printf '%s' "$content" > "$path"
    if [ $? -eq 0 ]; then
        echo "Write successful."
    else
        echo "Error: write failed."
    fi
}

run_bash() {
    local cmd="$1"

    # ---------- 权限检查（黑白名单） ----------
    # 黑名单检查
    for pattern in "${BASH_BLACKLIST[@]}"; do
        if [[ "$cmd" =~ $pattern ]]; then
            echo "❌ Command denied: matches blacklist pattern '$pattern'." >&2
            return 1
        fi
    done
    # 白名单检查
    local allowed=0
    for pattern in "${BASH_WHITELIST[@]}"; do
        if [[ "$cmd" =~ $pattern ]]; then
            allowed=1
            break
        fi
    done
    # 若既非黑名单也非白名单，询问用户
    if [ $allowed -eq 0 ]; then
        echo "⚠️  Command '$cmd' is not in whitelist." >&2
        read -p "Allow execution? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Command denied by user."
            return 1
        fi
    fi

    # 执行命令
    output=$(bash -c "$cmd" 2>&1)
    echo "$output"
}

ask_user() {
    local question="$1"
    echo "[Agent asks] $question"
    read -p "Your answer: " answer
    echo "$answer"
}

# ====================== Tools 定义（Function Calling 格式） ======================
TOOLS_JSON='[
  {
    "type": "function",
    "function": {
      "name": "read",
      "description": "Read content of a file. Returns the file contents or an error if the file is not found.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_path": {
            "type": "string",
            "description": "Path to the file to read (relative or absolute)"
          }
        },
        "required": ["file_path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write",
      "description": "Write content to a file. Has permission checks: system paths are denied, temp paths are auto-allowed, other paths require user confirmation.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "File path to write to"
          },
          "content": {
            "type": "string",
            "description": "Content to write to the file"
          }
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Execute a shell command. Has permission checks: dangerous commands are blocked, safe commands are auto-allowed, other commands require user confirmation. Returns stdout and stderr combined.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "Shell command to execute"
          }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "ask",
      "description": "Ask the user a question to get information needed to complete the task.",
      "parameters": {
        "type": "object",
        "properties": {
          "question": {
            "type": "string",
            "description": "Question to ask the user"
          }
        },
        "required": ["question"]
      }
    }
  }
]'

# System prompt — 不再强制格式，让模型自然输出思考
SYSTEM_PROMPT='You are an AI assistant that can use tools to accomplish tasks.
You have access to the following tools:
- read: Read content of a file
- write: Write content to a file
- bash: Execute a shell command
- ask: Ask the user a question

Use these tools when you need to interact with the system or get information.
Think step by step — your reasoning will be visible to the user.
When you have enough information, provide the final answer directly.
'

# ====================== 执行工具调用 ======================
# 执行单个工具调用，将工具名和参数输出到 stderr，结果输出到 stdout
# 调用方通过命令替换捕获结果
execute_tool_call() {
    local tool_name="$1"
    local tool_args="$2"

    echo "🔧 Tool: $tool_name $tool_args" >&2

    case "$tool_name" in
        read)
            local path=$(echo "$tool_args" | jq -r '.file_path // empty')
            if [ -z "$path" ]; then
                echo "Error: missing required argument 'file_path'"
                return
            fi
            read_file "$path"
            ;;
        write)
            local path=$(echo "$tool_args" | jq -r '.path // empty')
            local content=$(echo "$tool_args" | jq -r '.content // empty')
            if [ -z "$path" ] || [ -z "$content" ]; then
                echo "Error: missing required argument 'path' or 'content'"
                return
            fi
            write_file "$path" "$content"
            ;;
        bash)
            local cmd=$(echo "$tool_args" | jq -r '.command // empty')
            if [ -z "$cmd" ]; then
                echo "Error: missing required argument 'command'"
                return
            fi
            run_bash "$cmd"
            ;;
        ask)
            local question=$(echo "$tool_args" | jq -r '.question // empty')
            if [ -z "$question" ]; then
                echo "Error: missing required argument 'question'"
                return
            fi
            ask_user "$question"
            ;;
        *)
            echo "Error: unknown tool '$tool_name'"
            ;;
    esac
}

# ====================== 主 Agent 循环 ======================
run_agent() {
    local user_task="$1"
    local messages=$(jq -n \
        --arg system "$SYSTEM_PROMPT" \
        --arg user "$user_task" \
        '[{"role":"system","content":$system},{"role":"user","content":$user}]')

    echo "🧠 Agent started. Type /exit to quit."

    local max_iterations=20
    local iter=0

    while [ $iter -lt $max_iterations ]; do
        iter=$((iter + 1))
        echo "--- Turn $iter ---"

        # 调用 API（带 tools 参数）
        # 通过临时文件传递 messages（避免 ARG_MAX 限制）
        local response
        local _msgfile
        _msgfile=$(mktemp)
        printf '%s' "$messages" > "$_msgfile"

        response=$(jq -n \
            --arg model "$MODEL" \
            --argjson tools "$TOOLS_JSON" \
            --slurpfile msgs "$_msgfile" \
            '{model: $model, messages: $msgs[0], tools: $tools}' | \
            curl -s --connect-timeout 30 --max-time 120 \
                "$API_BASE/chat/completions" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $API_KEY" \
                -d @-) || {
            local _curl_exit=$?
            rm -f "$_msgfile"
            echo "❌ Network error: curl failed (exit code $_curl_exit)"
            break
        }
        rm -f "$_msgfile"

        # 检查 API 返回的业务错误
        local api_error=$(echo "$response" | jq -r '.error.message // empty')
        if [ -n "$api_error" ]; then
            echo "❌ API error: $api_error"
            break
        fi

        # 检查响应是否为空
        if [ -z "$response" ]; then
            echo "❌ API error: empty response"
            break
        fi

        # 提取 assistant 消息
        local assistant_msg=$(echo "$response" | jq '.choices[0].message // empty')
        if [ -z "$assistant_msg" ] || [ "$assistant_msg" = "null" ]; then
            echo "❌ API error: unexpected response format"
            break
        fi

        local finish_reason=$(echo "$response" | jq -r '.choices[0].finish_reason')
        local content=$(echo "$assistant_msg" | jq -r '.content // empty')

        # 显示模型思考过程
        if [ -n "$content" ]; then
            echo "🤖 $content"
        fi

        # 检查是否结束（无工具调用）
        if [ "$finish_reason" = "stop" ]; then
            echo "✅ Done."
            break
        fi

        # 将 assistant 消息加入 context
        messages=$(echo "$messages" | jq --argjson msg "$assistant_msg" '. + [$msg]')

        # 处理所有工具调用（支持并行 tool_calls）
        local tool_calls=$(echo "$assistant_msg" | jq '.tool_calls // []')
        local tool_count=$(echo "$tool_calls" | jq 'length')

        for ((i=0; i<tool_count; i++)); do
            local tool_name=$(echo "$tool_calls" | jq -r ".[$i].function.name")
            local tool_args=$(echo "$tool_calls" | jq -r ".[$i].function.arguments")
            local tool_id=$(echo "$tool_calls" | jq -r ".[$i].id")

            # capture stdout (tool result), let stderr (status messages) pass through
            local tool_result
            tool_result=$(execute_tool_call "$tool_name" "$tool_args")
            echo "📋 $tool_result"

            # 构造 tool result 消息加入 context
            # 通过 stdin 传递 tool_result（避免 ARG_MAX 限制）
            local _toolmsg_file
            _toolmsg_file=$(mktemp)
            printf '%s' "$tool_result" | jq -Rs --arg id "$tool_id" \
                '{role: "tool", tool_call_id: $id, content: .}' > "$_toolmsg_file"

            messages=$(echo "$messages" | jq --slurpfile msg "$_toolmsg_file" '. + [$msg[0]]')
            rm -f "$_toolmsg_file"
        done

        if [ $iter -eq $max_iterations ]; then
            echo "⚠️  Max iterations reached."
        fi
    done
}

# ====================== 主入口 ======================
if [ -z "${API_BASE:-}" ]; then
    read -p "API Base (e.g., https://api.openai.com/v1): " API_BASE
fi
API_BASE="${API_BASE%/}"
if [ -z "${API_KEY:-}" ]; then
    read -p "API Key: " API_KEY
    echo
fi

if command -v fzf &>/dev/null; then
    echo "Fetching available models..."
    MODEL=$(curl -s "$API_BASE/models" -H "Authorization: Bearer $API_KEY" | jq -r '.data[].id' | fzf --prompt="Select a model: ")
else
    read -p "Enter model ID (e.g., gpt-3.5-turbo): " MODEL
fi
if [ -z "${MODEL:-}" ]; then
    echo "No model selected. Exiting."
    exit 1
fi
echo "Using model: $MODEL"

echo "Enter your task (or type '/exit' to quit):"
while true; do
    read -p "Task: " task
    if [[ "$task" == "/exit" || "$task" == "quit" ]]; then
        echo "Goodbye!"
        break
    fi
    if [ -z "$task" ]; then
        continue
    fi
    run_agent "$task"
    echo "-----------------------"
done
