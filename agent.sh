#!/bin/bash
set -euo pipefail

# 退出时清理临时文件
cleanup_temp_files() {
    rm -f /tmp/agent-bash-*
}
trap cleanup_temp_files EXIT

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

# Bash 命令的黑名单（全文子串匹配，单词边界防误杀）
BASH_BLACKLIST=(
    '\<rm\>'
    '\<dd\>'
    'mkfs'
    ':\(\)\{'
    '> /dev/sd'
    'chmod 777 /'
    'chown -R /'
    '\<kill\>'
    'pkill'
    'killall'
)
# Bash 命令的白名单（正则，匹配整个命令字符串的开头）
BASH_WHITELIST=(
    '^ls\b'
    '^pwd\b'
    '^grep\b'
    '^wc\b'
    '^find\b'
    '^head\b'
    '^tail\b'
    '^sort\b'
)

# 截断默认阈值
MAX_LINES=200
MAX_BYTES=10240  # 10KB

########分割线
center_line() {
    local title=" ${1:-} "                     # 标题两侧加空格，视觉更舒展
    local char="${2:-=}"                   # 默认填充符为 "="
    local cols=$(tput cols)                # 获取当前终端宽度
    
    # 关键：用 wc -m 统计字符数（正确处理中文/emoji）
    local title_len=$(printf "%s" "$title" | wc -m)
    
    # 若标题过长，直接打印并换行
    if [ $title_len -ge $cols ]; then
        echo "$title"
        return
    fi
    
    # 计算左右填充长度（处理奇数宽度，右侧多补1个）
    local left_len=$(( (cols - title_len) / 2 ))
    local right_len=$(( cols - title_len - left_len ))
    
    # 生成填充字符串（将空格替换为指定字符）
    printf -v left "%*s" "$left_len" ""
    printf -v right "%*s" "$right_len" ""
    left="${left// /$char}"
    right="${right// /$char}"
    
    # 合并输出
    printf "%s%s%s\n" "$left" "$title" "$right"
}

# ====================== 通用截断函数 ======================

# 从头截取：从 content 开头截取最多 max_lines 行 / max_bytes 字节（先到为准）
# 被截断时自动追加 continuation hint
truncate_head() {
    local content="$1"
    local max_lines="${2:-$MAX_LINES}"
    local max_bytes="${3:-$MAX_BYTES}"

    local all_lines=()
    local IFS=$'\n'
while IFS= read -r line; do
        all_lines+=("$line")
    done <<< "$content"

    local total_lines=${#all_lines[@]}
    # 去掉可能的尾部空行（trailing newline 产生的空串）
    if [ $total_lines -gt 0 ] && [ -z "${all_lines[$total_lines-1]:-}" ]; then
        total_lines=$((total_lines - 1))
    fi

    local out_lines=()
    local byte_count=0
    local truncated=0

    for ((i=0; i<total_lines; i++)); do
        local line="${all_lines[$i]:-}"
        # 检查行数限制
        if [ ${#out_lines[@]} -ge $max_lines ]; then
            truncated=1
            break
        fi
        local line_bytes
        line_bytes=$(printf '%s' "$line" | wc -c)
        local new_bytes=$((byte_count + line_bytes + 1))
        if [ $new_bytes -gt $max_bytes ] && [ ${#out_lines[@]} -gt 0 ]; then
            truncated=1
            break
        fi
        # 首行超限特殊处理
        if [ ${#out_lines[@]} -eq 0 ] && [ $line_bytes -gt $max_bytes ]; then
            echo "[Line 1 is $line_bytes bytes, exceeds ${max_bytes}B limit. Use bash to read with head/tail.]"
            return
        fi
        out_lines+=("$line")
        byte_count=$new_bytes
    done

    local output
    output=$(printf '%s\n' "${out_lines[@]}")
    local out_count=${#out_lines[@]}

    if [ $truncated -eq 1 ] && [ $out_count -gt 0 ]; then
        local next_offset=$((out_count + 1))
        output="$output"$'\n'"% [Showing lines 1-${out_count} of ${total_lines}. Use offset=${next_offset} to continue.]"
    fi

    echo "$output"
}

# 从尾截取：从 content 末尾截取最多 max_lines 行 / max_bytes 字节（先到为准）
# 被截断时保存完整内容到临时文件并在结果中提示路径
truncate_tail() {
    local content="$1"
    local max_lines="${2:-$MAX_LINES}"
    local max_bytes="${3:-$MAX_BYTES}"

    local all_lines=()
    local IFS=$'\n'
    while IFS= read -r line; do
        all_lines+=("$line")
    done <<< "$content"

    local total_lines=${#all_lines[@]}
    if [ $total_lines -gt 0 ] && [ -z "${all_lines[$total_lines-1]:-}" ]; then
        total_lines=$((total_lines - 1))
    fi

    # 检查是否需要截断
    local total_bytes=0
    local i
    for ((i=0; i<total_lines; i++)); do
        local line_bytes
        line_bytes=$(printf '%s' "${all_lines[$i]:-}" | wc -c)
        total_bytes=$((total_bytes + line_bytes + 1))
    done
    if [ $total_lines -le $max_lines ] && [ $total_bytes -le $max_bytes ]; then
        echo "$content"
        return
    fi

    # 从尾向前遍历
    local out_lines=()
    local byte_count=0

    for ((i=total_lines-1; i>=0; i--)); do
        local line="${all_lines[$i]:-}"
        if [ ${#out_lines[@]} -ge $max_lines ]; then
            break
        fi
        local line_bytes
        line_bytes=$(printf '%s' "$line" | wc -c)
        local new_bytes=$((byte_count + line_bytes + 1))
        if [ $new_bytes -gt $max_bytes ] && [ ${#out_lines[@]} -gt 0 ]; then
            break
        fi
        out_lines=("$line" "${out_lines[@]}")
        byte_count=$new_bytes
    done

    local output
    output=$(printf '%s\n' "${out_lines[@]}")
    local out_count=${#out_lines[@]}

    # 被截断的部分保存到临时文件
    local full_output_file
    full_output_file=$(mktemp /tmp/agent-bash-XXXXXX)
    printf '%s' "$content" > "$full_output_file"
    output="$output"$'\n'"% [Showing last ${out_count} of ${total_lines} lines. Full output: ${full_output_file}]"

    echo "$output"
}

# ====================== Markdown 渲染 ======================
# 如果安装了 glow，用 glow 渲染 markdown；否则原样输出
render_md() {
    local text="$1"
    if [ -z "$text" ]; then
        return
    fi
    if command -v glow &>/dev/null; then
        echo "$text" | glow -
    else
        echo "$text"
    fi
}

# ====================== 工具函数 ======================
read_file() {
    local path="$1"
    local offset="${2:-}"
    local limit="${3:-}"

    if [ ! -f "$path" ]; then
        echo "Error: file not found"
        return
    fi

    local content
    content=$(cat "$path" 2>/dev/null) || {
        echo "Error: cannot read file"
        return
    }

    # 按 offset/limit 切分行
    if [ -n "$offset" ] || [ -n "$limit" ]; then
        local all_lines=()
        local IFS=$'\n'
        while IFS= read -r line; do
            all_lines+=("$line")
        done <<< "$content"

        local total=${#all_lines[@]}
        # 去掉尾部空行
        if [ $total -gt 0 ] && [ -z "${all_lines[$total-1]:-}" ]; then
            total=$((total - 1))
        fi

        local start=0
        if [ -n "$offset" ]; then
            start=$((offset - 1))
            [ $start -lt 0 ] && start=0
            if [ $start -ge $total ]; then
                echo "Error: offset $offset is beyond end of file ($total lines total)"
                return
            fi
        fi

        local slice_lines=()
        if [ -n "$limit" ]; then
            local end=$((start + limit))
            [ $end -gt $total ] && end=$total
            for ((i=start; i<end; i++)); do
                slice_lines+=("${all_lines[$i]:-}")
            done
        else
            for ((i=start; i<total; i++)); do
                slice_lines+=("${all_lines[$i]:-}")
            done
        fi

        content=$(printf '%s\n' "${slice_lines[@]}")
    fi

    # 自动截断
    truncate_head "$content"
}

write_file() {
    local path="$1"
    local content="$2"

    # 执行写入
    mkdir -p "$(dirname "$path")" 2>/dev/null
    printf '%s' "$content" > "$path"
    if [ $? -eq 0 ]; then
        local written
        written=$(printf '%s' "$content" | wc -c)
        echo "Successfully wrote ${written} bytes to ${path}"
    else
        echo "Error: write failed."
    fi
}

# ====================== Edit 模式函数 ======================
# 执行精确文本替换（edit 模式，默认模式）
# 参数: path, edits_json (JSON 数组: [{"oldText":..., "newText":...}])
# 从后往前应用 edits，保持位置不变
_write_edit() {
    local path="$1"
    local edits_json="$2"

    # 读取文件
    local content
    content=$(cat "$path") || { echo "Error: cannot read $path"; return 1; }

    local edit_count
    edit_count=$(echo "$edits_json" | jq 'length')
    [ "$edit_count" -eq 0 ] && { echo "Error: edits array is empty"; return 1; }

    # 从后往前应用（保持位置不变）
    local i
    for ((i=edit_count-1; i>=0; i--)); do
        local oldText newText
        oldText=$(echo "$edits_json" | jq -r ".[$i].oldText // empty")
        newText=$(echo "$edits_json" | jq -r ".[$i].newText // empty")

        [ -z "$oldText" ] && { echo "Error: edit $i has empty oldText"; return 1; }

        # 用 bash 字符串操作计算出现次数（纯字符级匹配）
        local modified="${content//"$oldText"/}"
        local clen=${#content}
        local mlen=${#modified}
        local olen=${#oldText}
        local count=$(( (clen - mlen) / olen ))

        if [ "$count" -eq 0 ]; then
            echo "Error: edit $i: oldText not found in file"; return 1
        elif [ "$count" -gt 1 ]; then
            echo "Error: edit $i: oldText found $count times (must be unique)"; return 1
        fi

        # 替换第一个匹配
        local before="${content%%"$oldText"*}"
        local after="${content#*"$oldText"}"
        content="${before}${newText}${after}"
    done

    # 保存原始内容用于 diff
    local original
    original=$(cat "$path")

    # 写回文件
    printf '%s' "$content" > "$path"

    # 生成 diff 摘要
    local diff_output
    diff_output=$(diff -u --label "$path" --label "$path" \
      <(printf '%s' "$original") <(printf '%s' "$content") 2>/dev/null || true)
    local changed
    changed=$(echo "$diff_output" | grep -c '^[-+][^-+]' 2>/dev/null || echo 0)

    echo "Edited $edit_count block(s) in $path ($changed lines changed)"
    if [ -n "$diff_output" ]; then
        echo "$diff_output"
    fi
}

# ====================== Patch 应用函数 ======================
_apply_patch() {
    local path="$1"
    local diff_content="$2"

    # 检查 patch 命令可用性
    if ! command -v patch >/dev/null 2>&1; then
        echo "Error: 'patch' command not available. Install patch first."
        return 1
    fi

    # 创建临时文件（不用 trap：函数在子 shell 调用中，trap 不可靠）
    local tmpfile
    tmpfile=$(mktemp /tmp/agent-bash-patch-XXXXXX)

    # 写入 diff 内容
    printf '%s\n' "$diff_content" > "$tmpfile"

    # 检测是否为新文件场景（--- /dev/null）
    local is_new_file=0
    if grep -q '^--- /dev/null' "$tmpfile" 2>/dev/null; then
        is_new_file=1
    fi

    # 计算预期 hunk 数（@@ -X,Y +Z,W @@ 的行数）
    local total_hunks
    total_hunks=$(grep -c '^@@ ' "$tmpfile" 2>/dev/null || echo 0)

    # 新文件场景：跳过 dry-run（/dev/null dry-run 行为不一致）
    if [ "$is_new_file" -eq 1 ]; then
        : # skip dry-run for new files
    else
        # dry-run 验证补丁：失败则提前退出
        local dry_run_output
        if ! dry_run_output=$(patch --dry-run --input="$tmpfile" --forward "$path" 2>&1); then
            echo "Patch dry-run failed for ${path}:"
            echo "$dry_run_output"
            return 1
        fi
    fi

    # 实际应用补丁（不用 --quiet，保留输出用于统计）
    local patch_output
    patch_output=$(patch --input="$tmpfile" --forward "$path" 2>&1)
    local rc=$?

    if [ $rc -eq 0 ]; then
        # 统计已应用 vs 跳过的 hunk
        local applied_hunks
        applied_hunks=$(echo "$patch_output" | grep -c 'patched' 2>/dev/null || echo "$total_hunks")
        local skipped_hunks=$((total_hunks - applied_hunks))
        # 变更行数：排除 --- 和 +++ diff header 行
        local lines_changed
        lines_changed=$(printf '%s\n' "$diff_content" | grep -c '^[-+][^-+]' 2>/dev/null || echo 0)

        if [ $skipped_hunks -gt 0 ]; then
            echo "Applied ${applied_hunks}/${total_hunks} hunks, ${skipped_hunks} already applied (${lines_changed} lines changed)"
        else
            echo "Successfully applied patch to ${path} (${total_hunks} hunks, ${lines_changed} lines changed)"
        fi
    else
        # 提取具体错误信息
        local err_detail
        err_detail=$(echo "$patch_output" | head -5)
        echo "Hunks failed: ${err_detail}"
        return 1
    fi
}

run_bash() {
    local cmd="$1"
    local timeout_sec="${2:-}"

    # 执行命令（可选超时）
    local output
    if [ -n "$timeout_sec" ] && [ "$timeout_sec" -gt 0 ] 2>/dev/null; then
        output=$(timeout "$timeout_sec" bash -c "$cmd" 2>&1) || {
            local rc=$?
            if [ $rc -eq 124 ]; then
                echo "Command timed out after ${timeout_sec} seconds"
                return
            fi
            # 非超时错误——依然输出已有结果
            echo "$output"
            return
        }
    else
        output=$(bash -c "$cmd" 2>&1)
    fi

    # 输出截断
    truncate_tail "$output"
}

ask_user() {
    local question="$1"
    echo "[Agent asks] $question"
    read -p "Your answer: " answer
    echo "$answer"
}

# ====================== 权限与钩子 ======================

# before_tool_call: 在工具执行前进行权限检查
# 参数: tool_name, tool_args_json
# 返回: 0=放行, 1=拒绝（_block_reason 包含拒绝原因）
_before_tool_call() {
    local tool_name="$1"
    local tool_args="$2"

    case "$tool_name" in
        write)
            local path
            path=$(echo "$tool_args" | jq -r '.path // empty')
            [ -z "$path" ] && return 0  # 参数错误让 execute 处理

            # 黑名单检查
            for pattern in "${WRITE_BLACKLIST[@]}"; do
                if [[ "$path" =~ $pattern ]]; then
                    _block_reason="Write denied: path matches blacklist pattern '$pattern'."
                    return 1
                fi
            done
            # 白名单检查
            for pattern in "${WRITE_WHITELIST[@]}"; do
                if [[ "$path" =~ $pattern ]]; then
                    return 0
                fi
            done
            # 交互确认
            echo "⚠️  Write to '$path' is not in whitelist." >&2
            read -p "Allow write? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                _block_reason="Write denied by user."
                return 1
            fi
            return 0
            ;;

        bash)
            local cmd
            cmd=$(echo "$tool_args" | jq -r '.command // empty')
            [ -z "$cmd" ] && return 0

            # 黑名单检查
            for pattern in "${BASH_BLACKLIST[@]}"; do
                if [[ "$cmd" =~ $pattern ]]; then
                    _block_reason="Command denied: matches blacklist pattern '$pattern'."
                    return 1
                fi
            done
            # 白名单检查
            for pattern in "${BASH_WHITELIST[@]}"; do
                if [[ "$cmd" =~ $pattern ]]; then
                    return 0
                fi
            done
            # 交互确认
            echo "⚠️  Command '$cmd' is not in whitelist." >&2
            read -p "Allow execution? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                _block_reason="Command denied by user."
                return 1
            fi
            return 0
            ;;

        *)
            return 0
            ;;
    esac
}

# after_tool_call: 工具执行后的后处理
# 参数: tool_name, tool_result
# 输出: 可能修改后的结果
_after_tool_call() {
    local tool_name="$1"
    local tool_result="$2"
    echo "$tool_result"
}

# ====================== Tools 定义（Function Calling 格式） ======================
TOOLS_JSON='[
  {
    "type": "function",
    "function": {
      "name": "read",
      "description": "Read content of a file. Supports offset/limit for large files. Large files are automatically truncated to 200 lines and 10KB. Use offset to read more. Returns file contents or an error.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_path": {
            "type": "string",
            "description": "Path to the file to read (relative or absolute)"
          },
          "offset": {
            "type": "integer",
            "description": "Line number to start reading from (1-indexed, optional)"
          },
          "limit": {
            "type": "integer",
            "description": "Maximum number of lines to read (optional)"
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
      "description": "Edit or patch a file. mode='edit' (default): replace exact text blocks using oldText/newText pairs. Each edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect nearby lines, merge them into one edit. mode='patch': apply a unified diff for large structural changes. Has permission checks: system paths denied, temp paths auto-allowed, others require confirmation.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "File path to write to"
          },
          "edits": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "oldText": {
                  "type": "string",
                  "description": "Exact text to find (must be unique in the file)"
                },
                "newText": {
                  "type": "string",
                  "description": "Replacement text"
                }
              },
              "required": ["oldText", "newText"]
            },
            "description": "Array of oldText/newText replacements. Each oldText must be unique in the file. Merge nearby changes into one edit instead of overlapping edits."
          },
          "content": {
            "type": "string",
            "description": "Unified diff content (required for mode='patch')"
          },
          "mode": {
            "type": "string",
            "enum": ["edit", "patch"],
            "default": "edit",
            "description": "Edit mode (default): replace exact text blocks via edits[].oldText→newText. Patch mode: apply a unified diff."
          }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Execute a shell command. Has permission checks: dangerous commands are blocked, safe commands are auto-allowed, other commands require user confirmation. Output is truncated to last 200 lines and 10KB. Optionally provide a timeout in seconds.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "Shell command to execute"
          },
          "timeout": {
            "type": "integer",
            "description": "Timeout in seconds (optional)"
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
  },
  {
    "type": "function",
    "function": {
      "name": "load_skill",
      "description": "Load a skill to gain specialized instructions and workflows for a specific task. Returns the full skill content and its file path. Only load skills from the available skills list.",
      "parameters": {
        "type": "object",
        "properties": {
          "skill_name": {
            "type": "string",
            "description": "The exact name of the skill to load (must match a name in the available skills list)"
          }
        },
        "required": ["skill_name"]
      }
    }
  }
]'

# ====================== 技能元数据收集 ======================
# 扫描技能目录，提取 name + description，输出 JSON 数组
collect_skills_metadata() {
    local skills_dir="$1"
    local cache_file="$2"

    [ -d "$skills_dir" ] || return 0

    local json_items=""

    for skill_md in "$skills_dir"/*/SKILL.md; do
        [ -f "$skill_md" ] || continue

        local name_raw desc_raw
        # 用 sed 提取 frontmatter 中的 name 和 description 行（不含 yq）
        name_raw=$(sed -n '1,/^---/{/^---$/d;/^name: /s/^name: *//p}' "$skill_md" | head -1)
        desc_raw=$(sed -n '1,/^---/{/^---$/d;/^description: /s/^description: *//p}' "$skill_md" | head -1)

        # 跳过无 name 的
        [ -z "$name_raw" ] && continue

        local item
        item=$(jq -n --arg n "$name_raw" --arg d "${desc_raw:-"(no description)"}" '{"name":$n,"description":$d}')

        if [ -z "$json_items" ]; then
            json_items="$item"
        else
            json_items="$json_items"$'\n'"$item"
        fi
    done

    [ -z "$json_items" ] && return 0

    # 输出为 JSON 数组
    echo "$json_items" | jq -s '.' > "$cache_file"
}

# ====================== System Prompt ======================
# 构建 system prompt（动态：运行时会注入 AGENTS.md 内容）
build_system_prompt() {
    local prompt='You are an AI assistant that can use tools to accomplish tasks.
You have access to the following tools:
- read: Read content of a file (supports offset/limit for large files)
- write: Edit or patch a file. Use mode="edit" (default) for precise oldText→newText replacement. Use mode="patch" to apply a unified diff. Each edits[].oldText must match exactly once in the file. For multiple changes in one file, use one write call with multiple entries in edits[] instead of separate calls.
- bash: Execute a shell command (has permission checks, timeout optional, output truncated)
- ask: Ask the user a question
- load_skill: Load a skill to gain specialized instructions and workflows (provide skill name). Returns the full skill content and its file path.

Use these tools when you need to interact with the system or get information.
Think step by step — your reasoning will be visible to the user.
When you have enough information, provide the final answer directly.

## Tool Philosophy
- Use **edit** mode (default) for precise targeted changes. Keep oldText as short as possible while still unique in the file.
- When changing multiple separate locations, use one write call with multiple entries in edits[] rather than separate calls.
- Each edits[].oldText is matched against the **original** file, not after earlier edits. Do not emit overlapping edits — merge nearby changes into one edit instead.
- Use **patch** mode for large structural changes (e.g., adding new functions, reordering blocks) where a unified diff is more convenient than multiple edits.
- Do not make decisions for the user; ask them for confirmation on unclear requirements.

## Core Code of Conduct

## 2. Interaction Guidelines

- When encountering user errors, point them out honestly, without flattery or concealment.

- Avoid celebrations (avoid saying "perfect" or "definitely normal"), use phrases like "please test" or "no anomalies found so far."

## 4. Coding Principles

- **Think First**: Define assumptions clearly, ask questions when confused, and list multiple explanations.

- **Simplicity First**: Use minimal code, avoid excessive abstraction, and dont write unnecessary error handling.

- **Surgical Modification**: Only modify what is necessary, maintain the original style, and delete unused code resulting from changes.

- **Goal-Driven**: Transform tasks into verifiable sub-goals, iteratively verifying until successful.

## 7. RTK (Rust Token Killer) Usage

**Core Rule**: Prepend `rtk` to all commands (including each command in the `&&` chain).

Typical Example:

```bash
rtk cargo build / check / clippy # Saves 80-90% of compilation output
rtk cargo test / `vitest run` # Saves 90-99% on failed tests

`rtk git status / log / diff` # Saves 59-80% on Git output

`rtk pnpm install / list` # Saves 70-90% on package manager output

The same applies to other commands (docker, kubectl, gh, curl, etc.); `rtk` automatically filters redundant output.

You can use `rtk gain` to view the savings statistics and `rtk discover` to analyze missed usage.


## Available Skills
<skills_metadata>
'

    if [ "${SKILLS_PROMPT:-1}" = "1" ] && [ -f "/tmp/agent-bash-skills-meta.json" ]; then
        prompt="$prompt"$(cat /tmp/agent-bash-skills-meta.json)
    fi

    prompt="$prompt"$'\n'"</skills_metadata>"
    local others="Now date is $(date),Current path(you are work in) is $(pwd),You must ansower user with $LANG"

    # 加载 AGENTS.md
    local agents_content
    agents_content=$(load_agents_md)
    if [ -n "$agents_content" ]; then
        prompt="$prompt"$'\n\n'"<project_instructions>"
        prompt="$prompt"$'\n'"${agents_content}"
        prompt="$prompt"$'\n'"${others}"
        prompt="$prompt"$'\n'"</project_instructions>"
    fi

    echo "$prompt"
}

# ====================== AGENTS.md 加载 ======================
# 从当前目录向上遍历，在遇到 .git/.jj 时停止
# 没有仓库时只看当前目录
load_agents_md() {
    local dir
    dir=$(pwd)

    while true; do
        # 检查当前目录
        for f in "AGENTS.md" "AGENTS.MD" "CLAUDE.md" "CLAUDE.MD"; do
            local candidate="$dir/$f"
            if [ -f "$candidate" ]; then
                cat "$candidate" 2>/dev/null
                return
            fi
        done

        # 检查是否到达项目边界
        if [ -d "$dir/.git" ] || [ -d "$dir/.jj" ] || [ "$dir" = "/" ]; then
            break
        fi

        # 上一级
        local parent
        parent=$(dirname "$dir")
        if [ "$parent" = "$dir" ]; then
            break
        fi
        dir="$parent"
    done
}

# ====================== 会话管理 ======================
# 会话目录结构（在 sessions/<id>/ 下）：
#   meta.json      — 元数据（任务、创建时间、iteration 数）
#   system.md      — system prompt 文本（从 AGENTS.md 动态重建）
#   messages.jsonl — JSONL 消息历史（不含 system，恢复时从 system.md 拼接）
#   state.json     — 运行时状态（iteration、last_op）

# 生成会话 ID：时间戳 + 任务描述哈希 + 随机后缀（避免同名冲突）
generate_session_id() {
    local task_desc="${1:-untitled}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d-%H-%M')
    # 对任务描述做 md5 哈希（取前 12 字符）
    local task_hash
    task_hash=$(printf '%s' "$task_desc" | md5sum | cut -c1-12)
    # 4 位随机数
    local random_suffix
    random_suffix=$(printf '%04d' $((RANDOM % 10000)))
    echo "${timestamp}-${task_hash}-${random_suffix}"
}

# 初始化会话目录
# 参数: session_id, user_task
# 创建 sessions/<id>/ 并写入 meta.json、system.md、messages.jsonl、state.json
init_session() {
    local session_id="$1"
    local user_task="$2"
    local session_dir="sessions/${session_id}"

    mkdir -p "$session_dir"

    # 写入 meta.json
    jq -n \
        --arg id "$session_id" \
        --arg task "$user_task" \
        --arg created "$(date -Iseconds)" \
        '{id:$id,task:$task,created:$created,iterations:0,last_op:"init"}' \
        > "$session_dir/meta.json"

    # 写入 system prompt 文本
    build_system_prompt > "$session_dir/system.md"

    # 初始化 JSONL：只写 user 消息（system 从 system.md 恢复）
    jq -c -n \
        --arg user "$user_task" \
        '{role:"user",content:$user}' \
        > "$session_dir/messages.jsonl"

    # 初始化状态
    jq -n '{iterations:0,last_op:"init"}' > "$session_dir/state.json"

    echo "📁 Session: $session_id"
    echo "   Dir: $session_dir"
}

# 从 JSONL 加载会话消息 + 拼接 system prompt → 完整 messages JSON 字符串
# 参数: session_dir
# 输出: 完整的 messages JSON 数组（含 system + 历史消息）
load_session_messages() {
    local session_dir="$1"
    local system_content
    system_content=$(cat "$session_dir/system.md" 2>/dev/null) || {
        echo "Error: cannot read system.md"
        return 1
    }

    local jsonl_file="$session_dir/messages.jsonl"
    # 检查文件是否非空
    if [ ! -s "$jsonl_file" ]; then
        # 空 JSONL：只有 system 消息
        jq -n --arg system "$system_content" '[{role:"system",content:$system}]'
    else
        # 用 jq -s 直接读取 JSONL 文件（O(n) 而非 O(n²)）
        jq -s --arg system "$system_content" \
            '[{role:"system",content:$system}] + .' "$jsonl_file"
    fi
}

# 更新会话 state.json 中的 iteration 和 last_op
# 参数: session_dir, iterations, last_op
update_session_state() {
    local session_dir="$1"
    local iterations="$2"
    local last_op="$3"
    local state_file="$session_dir/state.json"
    if [ -f "$state_file" ]; then
        jq -n --argjson it "$iterations" --arg op "$last_op" \
            '{iterations:$it,last_op:$op}' > "$state_file"
    fi
    # 同步更新 meta.json 中的 iterations
    local meta_file="$session_dir/meta.json"
    if [ -f "$meta_file" ]; then
        local tmp
        tmp=$(mktemp)
        jq --argjson it "$iterations" '.iterations=$it' "$meta_file" > "$tmp" && mv "$tmp" "$meta_file"
    fi
}

# ====================== 斜杠命令 ======================
# /init: 初始化 AGENTS.md 模板
handle_slash_init() {
    local target_dir="${1:-$(pwd)}"
    local agents_file="$target_dir/AGENTS.md"

    echo "🛠️  /init — Creating AGENTS.md template at $agents_file"
    echo ""

    # 检查是否已存在
    if [ -f "$agents_file" ]; then
        echo "AGENTS.md already exists. Open it to edit: $agents_file"
        return
    fi

    local template='# AGENTS.md — 项目代理指令

## 项目概览
[描述这个项目的用途、技术栈和架构]

## 开发约定
- [编码规范、命名约定、测试要求等]
- [项目特定规则]

## 工作流
- [构建命令、测试命令、部署流程]
- [代码审查要求]

## VCS 使用原则
- [版本控制约定，如提交信息格式、分支策略]
'

    # 通过 write 权限检查写入
    local _block_reason=""
    if _before_tool_call "write" "{\"path\":\"$agents_file\",\"content\":\"\"}"; then
        printf '%s' "$template" > "$agents_file"
        echo "✅ Created $agents_file"
        echo "Edit it to define project-specific instructions for the agent."
    else
        echo "❌ ${_block_reason:-Write denied.}"
    fi
}

# 斜杠命令分发
handle_slash_command() {
    local input="$1"

    case "$input" in
        /init*)
            # 支持 /init <path> 指定目录
            local target_dir
            target_dir=$(echo "$input" | awk '{print $2}')
            [ -z "$target_dir" ] && target_dir="$(pwd)"
            handle_slash_init "$target_dir"
            return 0
            ;;

        /save)
            if [ -z "${SESSION_DIR:-}" ]; then
                echo "No active session to save. Run a task first."
                return 1
            fi
            # 创建 snapshots 目录
            mkdir -p sessions/snapshots
            local timestamp
            timestamp=$(date '+%Y%m%d-%H%M%S')
            local snapshot_file="sessions/snapshots/${timestamp}-${SESSION_DIR##*/}.tar.gz"
            # 打包整个 session 目录
            tar -czf "$snapshot_file" -C "$(dirname "$SESSION_DIR")" "$(basename "$SESSION_DIR")" 2>/dev/null || {
                echo "❌ Failed to create snapshot"
                return 1
            }
            echo "💾 Session snapshot saved: $snapshot_file"
            echo "   Size: $(du -h "$snapshot_file" | cut -f1)"
            return 0
            ;;

        /sessions)
            if [ ! -d "sessions" ]; then
                echo "No sessions found."
                return 0
            fi
            # 列出所有非 snapshots 的会话目录
            echo "📋 Sessions:"
            echo ""
            printf "%-38s %5s  %s\n" "ID" "Iter" "Task"
            printf "%s\n" "$(printf '=%.0s' {1..60})"
            for dir in sessions/[!s]*/; do
                [ -d "$dir" ] || continue
                local meta_file="$dir/meta.json"
                [ -f "$meta_file" ] || continue
                local id task iterations
                id=$(jq -r '.id' "$meta_file")
                task=$(jq -r '.task' "$meta_file" | head -c 50)
                iterations=$(jq -r '.iterations' "$meta_file")
                printf "%-38s %5s  %s\n" "$id" "$iterations" "$task"
            done
            return 0
            ;;

        /restore*)
            local session_name
            session_name=$(echo "$input" | awk '{print $2}')
            if [ -z "$session_name" ]; then
                echo "Usage: /restore <session_id_or_partial_name>"
                echo "   session_id format: YYYY-MM-DD-HH-MM-<hash:12>-<random:4>"
                return 1
            fi

            # 在 sessions 目录下查找匹配的目录
            local found_dir=""
            for dir in sessions/[!s]*/; do
                [ -d "$dir" ] || continue
                local id
                id=$(basename "$dir")
                if [[ "$id" == *"$session_name"* ]]; then
                    found_dir="$dir"
                    break
                fi
            done

            if [ -z "$found_dir" ]; then
                echo "❌ Session not found matching: $session_name"
                echo "Use /sessions to list available sessions."
                return 1
            fi

            SESSION_DIR="$found_dir"
            echo "📂 Session restored: $(basename "$SESSION_DIR")"
            echo "   Iterations: $(jq -r '.iterations' "$SESSION_DIR/state.json" 2>/dev/null || echo 0)"
            echo "   Task: $(jq -r '.task' "$SESSION_DIR/meta.json" 2>/dev/null || echo "unknown")"
            return 0
            ;;

        /help)
            echo "Available slash commands:"
            echo "  /init [path]       — Create AGENTS.md template in current or specified directory"
            echo "  /sessions          — List all sessions"
            echo "  /save              — Save current session as snapshot (tar.gz)"
            echo "  /restore <id>      — Restore a session by ID or partial match"
            echo "  /help              — Show this help"
            echo "  /quit, /exit       — Exit the agent"
            return 0
            ;;

        *)
            echo "Unknown slash command: $input. Try /help."
            return 1
            ;;
    esac
}

# ====================== 执行工具调用 ======================
# 执行单个工具调用（先经过 before_tool_call 钩子）
execute_tool_call() {
    local tool_name="$1"
    local tool_args="$2"

    # 权限检查
    _block_reason=""
    if ! _before_tool_call "$tool_name" "$tool_args"; then
        echo "❌ ${_block_reason:-Blocked by permission check.}"
        echo "🔧 Tool: $tool_name $tool_args" >&2
        return
    fi

    echo "🔧 Tool: $tool_name $tool_args" >&2

    local result=""
    case "$tool_name" in
        read)
            local path=$(echo "$tool_args" | jq -r '.file_path // empty')
            local offset=$(echo "$tool_args" | jq -r '.offset // empty')
            local limit=$(echo "$tool_args" | jq -r '.limit // empty')
            if [ -z "$path" ]; then
                echo "Error: missing required argument 'file_path'"
                return
            fi
            result=$(read_file "$path" "$offset" "$limit")
            ;;
        write)
            local path=$(echo "$tool_args" | jq -r '.path // empty')
            local mode=$(echo "$tool_args" | jq -r '.mode // "edit"')
            if [ -z "$path" ]; then
                echo "Error: missing required argument 'path'"
                return
            fi
            case "$mode" in
                edit)
                    local edits
                    edits=$(echo "$tool_args" | jq -c '.edits // []')
                    [ "$edits" = "[]" ] || [ -z "$edits" ] && {
                        echo "Error: missing required argument 'edits' for mode=edit"
                        return
                    }
                    result=$(_write_edit "$path" "$edits")
                    ;;
                patch)
                    local content=$(echo "$tool_args" | jq -r '.content // empty')
                    [ -z "$content" ] && {
                        echo "Error: missing required argument 'content' for mode=patch"
                        return
                    }
                    result=$(_apply_patch "$path" "$content")
                    ;;
                write)
                    local content=$(echo "$tool_args" | jq -r '.content // empty')
                    [ -z "$content" ] && {
                        echo "Error: missing required argument 'content' for mode=write"
                        return
                    }
                    result=$(write_file "$path" "$content")
                    ;;
            esac
            ;;
        bash)
            local cmd=$(echo "$tool_args" | jq -r '.command // empty')
            local timeout=$(echo "$tool_args" | jq -r '.timeout // empty')
            if [ -z "$cmd" ]; then
                echo "Error: missing required argument 'command'"
                return
            fi
            result=$(run_bash "$cmd" "$timeout")
            ;;
        ask)
            local question=$(echo "$tool_args" | jq -r '.question // empty')
            if [ -z "$question" ]; then
                echo "Error: missing required argument 'question'"
                return
            fi
            result=$(ask_user "$question")
            ;;
        load_skill)
            local skill_name=$(echo "$tool_args" | jq -r '.skill_name // empty')
            if [ -z "$skill_name" ]; then
                echo "Error: missing required argument 'skill_name'"
                return
            fi
            # 白名单校验：只允许字母数字、下划线、连字符
            if [[ ! "$skill_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo "Error: invalid skill name (only alphanumeric, hyphen, underscore allowed)"
                return
            fi
            local skill_md=""
            local OPENCODE_SKILLS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
            # 先搜 OpenCode skills 目录
            if [ -f "$OPENCODE_SKILLS_DIR/$skill_name/SKILL.md" ]; then
                skill_md="$OPENCODE_SKILLS_DIR/$skill_name/SKILL.md"
            # 再搜项目本地 skills 目录
            elif [ -f "$(pwd)/skills/$skill_name/SKILL.md" ]; then
                skill_md="$(pwd)/skills/$skill_name/SKILL.md"
            else
                echo "Error: skill '$skill_name' not found. Check the available skills list."
                return
            fi
            local content
            content=$(cat "$skill_md" 2>/dev/null) || {
                echo "Error: cannot read skill file at $skill_md"
                return
            }
            result="📁 Path: $skill_md"$'\n'"$(truncate_head "$content" 50 5000)"
            ;;
        *)
            echo "Error: unknown tool '$tool_name'"
            return
            ;;
    esac

    # 后处理
    result=$(_after_tool_call "$tool_name" "$result")
    echo "$result"
}

# Agent 主循环：从 session_dir 读取消息，每轮调用 API、执行工具、写入 JSONL
# 参数: session_dir, max_iterations
agent_loop() {
    local session_dir="$1"
    local max_iterations="${2:-20}"
    local messages
    messages=$(load_session_messages "$session_dir") || return 1

    local iter=0

    while [ $iter -lt $max_iterations ]; do
        iter=$((iter + 1))
        center_line "Turn $iter"

        # 调用 API（通过临时文件传递 messages，避免 ARG_MAX 限制）
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
        local api_error
        api_error=$(echo "$response" | jq -r '.error.message // empty')
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
        local assistant_msg
        assistant_msg=$(echo "$response" | jq '.choices[0].message // empty')
        if [ -z "$assistant_msg" ] || [ "$assistant_msg" = "null" ]; then
            echo "❌ API error: unexpected response format"
            break
        fi

        local finish_reason
        finish_reason=$(echo "$response" | jq -r '.choices[0].finish_reason')
        local content
        content=$(echo "$assistant_msg" | jq -r '.content // empty')
        local reasoning
        reasoning=$(echo "$assistant_msg" | jq -r '.reasoning_content // empty')

        # 显示推理过程（DeepSeek 风格）
        if [ -n "$reasoning" ]; then
            center_line "Thinking"
            echo "$reasoning"
            center_line "Response"
        fi

        # 显示模型思考过程（用 glow 格式化 markdown）
        if [ -n "$content" ]; then
            echo "🤖"
            render_md "$content"
        fi

        # 将 assistant 消息加入 context 并写入 JSONL（在 break 之前持久化）
        messages=$(echo "$messages" | jq --argjson msg "$assistant_msg" '. + [$msg]')
        printf '%s' "$assistant_msg" | jq -c '.' >> "$session_dir/messages.jsonl"

        # 检查是否结束（无工具调用）
        if [ "$finish_reason" = "stop" ]; then
            echo "✅ Done."
            break
        fi

        # 处理所有工具调用
        local tool_calls
        tool_calls=$(echo "$assistant_msg" | jq '.tool_calls // []')
        local tool_count
        tool_count=$(echo "$tool_calls" | jq 'length')

        for ((i=0; i<tool_count; i++)); do
            local tool_name
            tool_name=$(echo "$tool_calls" | jq -r ".[$i].function.name")
            local tool_args
            tool_args=$(echo "$tool_calls" | jq -r ".[$i].function.arguments")
            local tool_id
            tool_id=$(echo "$tool_calls" | jq -r ".[$i].id")

            # capture stdout, let stderr pass through
            local tool_result
            tool_result=$(execute_tool_call "$tool_name" "$tool_args")
            echo "📋 $tool_result"

            # 构造 tool result 消息
            local _toolmsg_file
            _toolmsg_file=$(mktemp)
            printf '%s' "$tool_result" | jq -Rs --arg id "$tool_id" \
                '{role: "tool", tool_call_id: $id, content: .}' > "$_toolmsg_file"

            # 读取并加入 context
            local tool_msg
            tool_msg=$(cat "$_toolmsg_file")
            messages=$(echo "$messages" | jq --argjson msg "$tool_msg" '. + [$msg]')
            # 写入 JSONL
            printf '%s' "$tool_msg" | jq -c '.' >> "$session_dir/messages.jsonl"
            rm -f "$_toolmsg_file"
        done

        # 更新会话状态
        update_session_state "$session_dir" "$iter" "tool_call"
    done

    # 更新最终 iteration 数
    update_session_state "$session_dir" "$iter" "done"
}

# ====================== 主 Agent 循环 ======================
run_agent() {
    local user_task="$1"
    local session_dir="${2:-}"  # 可选：会话目录路径

    # 缓存技能元数据（循环外，避免每轮重复扫描）
    local _opencode_cache="/tmp/agent-bash-skills-opencode.json"
    collect_skills_metadata "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" "$_opencode_cache"
    local _local_cache="/tmp/agent-bash-skills-local.json"
    local _merged_cache="/tmp/agent-bash-skills-meta.json"

    if [ -f "$_opencode_cache" ] && [ -f "$_local_cache" ]; then
        # 合并：保留 OpenCode 优先（同名 name 跳过项目本地）
        jq -n --slurpfile oc "$_opencode_cache" --slurpfile local "$_local_cache" \
          '($oc[0] | map(.name) | INDEX(.)) as $oc_map |
           $oc[0] + ($local[0] | map(select(.name as $n | ($oc_map | has($n)) | not)))' \
          > "$_merged_cache"
    elif [ -f "$_opencode_cache" ]; then
        cp "$_opencode_cache" "$_merged_cache"
    elif [ -f "$_local_cache" ]; then
        cp "$_local_cache" "$_merged_cache"
    fi
    rm -f "$_opencode_cache" "$_local_cache"

    if [ -n "$session_dir" ] && [ -f "$session_dir/messages.jsonl" ]; then
        # 恢复已有会话
        local session_id
        session_id=$(basename "$session_dir")
        SESSION_DIR="$session_dir"  # 保持全局同步（防御性）
        echo "📂 Restored session: $session_id (iterations: $(jq '.iterations' "$session_dir/state.json" 2>/dev/null || echo 0))"
        agent_loop "$SESSION_DIR"
    else
        # 新建会话
        local session_id
        session_id=$(generate_session_id "$user_task")
        init_session "$session_id" "$user_task"
        SESSION_DIR="sessions/${session_id}"  # 更新全局变量，后续轮次复用同一会话
        echo "🧠 Agent started. Type /exit to quit."
        agent_loop "$SESSION_DIR"
    fi
}

# ====================== 主入口 ======================

# 解析命令行参数
SESSION_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session)
            if [ $# -lt 2 ]; then
                echo "Error: --session requires an argument"
                exit 1
            fi
            SESSION_NAME="$2"
            SESSION_DIR="sessions/${SESSION_NAME}"
            if [ ! -f "$SESSION_DIR/messages.jsonl" ]; then
                echo "❌ Session not found: $SESSION_NAME"
                echo "Use /sessions to list available sessions."
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "${API_BASE:-}" ]; then
    read -p "API Base (e.g., https://api.openai.com/v1): " API_BASE
fi
API_BASE="${API_BASE%/}"
if [ -z "${API_KEY:-}" ]; then
    read -s -p "API Key: " API_KEY
    echo
fi


if [ -z "${MODEL:-}" ]; then
  if command -v fzf &>/dev/null; then
      echo "Fetching available models..."
      MODEL=$(curl -s "$API_BASE/models" -H "Authorization: Bearer $API_KEY" | jq -r '.data[].id' | fzf --prompt="Select a model: ")
  else
      read -p "Enter model ID (e.g., gpt-3.5-turbo): " MODEL
  fi
fi



if [ -z "${MODEL:-}" ]; then
    echo "No model selected. Exiting."
    exit 1
fi
echo "Using model: $MODEL"

echo "Enter your task (or type '/exit' or '/quit' to quit):"
while true; do
    read -p "Task: " task
    if [[ "$task" == "/exit" || "$task" == "/quit" || "$task" == "quit" ]]; then
        echo "Goodbye!"
        break
    fi
    if [ -z "$task" ]; then
        continue
    fi
    # 斜杠命令
    if [[ "$task" == /* ]]; then
        handle_slash_command "$task"
        center_line
        continue
    fi
    run_agent "$task" "$SESSION_DIR"
    center_line
done
