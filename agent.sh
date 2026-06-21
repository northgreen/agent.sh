#!/bin/bash

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
    'kill -9'
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
    echo "$content" > "$path"
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
    output=$(eval "$cmd" 2>&1)
    echo "$output"
}

ask_user() {
    local question="$1"
    echo "[Agent asks] $question"
    read -p "Your answer: " answer
    echo "$answer"
}

# ====================== 解析模型输出 ======================
parse_response() {
    local response="$1"
    if [[ "$response" =~ Final[[:space:]]+Answer:[[:space:]]*(.*) ]]; then
        echo "FINAL:${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$response" =~ Action:[[:space:]]*([a-zA-Z_]+)[[:space:]]*\[([^\]]*)\] ]]; then
        echo "ACTION:${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
        return 0
    fi
    echo "FINAL:$response"
}

# ====================== 主 Agent 循环 ======================
run_agent() {
    local user_task="$1"
    local system_prompt=$(cat <<EOF
You are an AI assistant that can use tools to accomplish tasks.
You have access to the following tools:
- read[file_path]       : Read content of a file.
- write[JSON]           : Write content to a file. JSON format: {"path":"...", "content":"..."}
- bash[command]         : Execute a shell command.
- ask[question]         : Ask the user for information.

You must respond in the exact format:
Thought: your reasoning...
Action: tool_name[arguments]

Or if you have the final answer:
Final Answer: your final response.

After you output an Action, you will receive an Observation with the result.
Then continue with Thought/Action or Final Answer.
EOF
)

    local messages=$(jq -n \
        --arg system "$system_prompt" \
        --arg user "$user_task" \
        '[{"role":"system","content":$system},{"role":"user","content":$user}]')

    echo "🧠 Agent started. Type /exit to quit."

    local max_iterations=10
    local iter=0

    while [ $iter -lt $max_iterations ]; do
        iter=$((iter + 1))
        echo "--- Iteration $iter ---"

        local response=$(curl -s "$API_BASE/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_KEY" \
            -d "$(jq -n --arg model "$MODEL" --argjson messages "$messages" '{
                model: $model,
                messages: $messages
            }')")

        local assistant_reply=$(echo "$response" | jq -r '.choices[0].message.content')
        if [ -z "$assistant_reply" ] || [ "$assistant_reply" = "null" ]; then
            echo "❌ API error: $response" | jq .
            break
        fi

        messages=$(echo "$messages" | jq --arg reply "$assistant_reply" '. + [{"role":"assistant","content":$reply}]')

        echo "🤖 Assistant:"
        echo "$assistant_reply"

        parse_result=$(parse_response "$assistant_reply")
        if [[ "$parse_result" =~ ^FINAL:(.*) ]]; then
            final_answer="${BASH_REMATCH[1]}"
            echo "✅ Final Answer: $final_answer"
            break
        elif [[ "$parse_result" =~ ^ACTION:([^:]+):(.*) ]]; then
            tool="${BASH_REMATCH[1]}"
            arg="${BASH_REMATCH[2]}"
            echo "🔧 Executing tool: $tool with arg: $arg"

            case "$tool" in
                read)
                    observation=$(read_file "$arg")
                    ;;
                write)
                    path=$(echo "$arg" | jq -r '.path')
                    content=$(echo "$arg" | jq -r '.content')
                    if [ -z "$path" ] || [ -z "$content" ]; then
                        observation="Error: invalid JSON for write. Need {\"path\":..., \"content\":...}"
                    else
                        observation=$(write_file "$path" "$content")
                    fi
                    ;;
                bash)
                    observation=$(run_bash "$arg")
                    ;;
                ask)
                    observation=$(ask_user "$arg")
                    ;;
                *)
                    observation="Error: unknown tool '$tool'"
                    ;;
            esac

            echo "📋 Observation: $observation"
            messages=$(echo "$messages" | jq --arg obs "Observation: $observation" '. + [{"role":"user","content":$obs}]')
        else
            echo "⚠️  No recognized format. Treating as final answer."
            echo "$assistant_reply"
            break
        fi

        if [ $iter -eq $max_iterations ]; then
            echo "⚠️  Max iterations reached."
        fi
    done
}

# ====================== 主入口 ======================
if [ -z "$API_BASE" ]; then
    read -p "API Base (e.g., https://api.openai.com/v1): " API_BASE
fi
if [ -z "$API_KEY" ]; then
    read -p "API Key: " API_KEY
fi

if command -v fzf &>/dev/null; then
    echo "Fetching available models..."
    MODEL=$(curl -s "$API_BASE/models" -H "Authorization: Bearer $API_KEY" | jq -r '.data[].id' | fzf --prompt="Select a model: ")
else
    read -p "Enter model ID (e.g., gpt-3.5-turbo): " MODEL
fi
if [ -z "$MODEL" ]; then
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
