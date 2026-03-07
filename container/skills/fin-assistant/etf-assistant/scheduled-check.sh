#!/bin/bash
# Scheduled Check - 检查并执行到期的定时任务
# 由 launchd 每小时调用

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ETF_ASSISTANT="$SCRIPT_DIR/container/skills/fin-assistant/etf-assistant/etf-assistant.sh"

# 默认 portfolio 路径
PORTFOLIO_FILE="${PORTFOLIO_FILE:-$SCRIPT_DIR/groups/fin-assistant/portfolio.json}"

# IPC 目录（挂载到容器内）
IPC_DIR="/workspace/ipc"
IPC_MESSAGES_DIR="$IPC_DIR/messages"

# 日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# 发送 IPC 消息
send_ipc_message() {
    local chat_jid="$1"
    local message="$2"

    if [ -z "$chat_jid" ] || [ -z "$message" ]; then
        return 1
    fi

    # 创建消息文件
    local msg_file="$IPC_MESSAGES_DIR/$(date +%s%N).json"
    cat > "$msg_file" << EOF
{
    "type": "message",
    "chatJid": "$chat_jid",
    "text": $message
}
EOF
    log "已发送 IPC 消息到 $chat_jid"
}

# 检查 cron 表达式是否需要现在执行
should_run() {
    local cron="$1"

    # 简单解析: 分 时 * * 周
    # 支持: "0 13 * * 1-5" 和 "0 9 * * 1,3,5" 格式
    local minute hour dom month dow

    minute=$(echo "$cron" | awk '{print $1}')
    hour=$(echo "$cron" | awk '{print $2}')
    dom=$(echo "$cron" | awk '{print $3}')
    month=$(echo "$cron" | awk '{print $4}')
    dow=$(echo "$cron" | awk '{print $5}')

    # 获取当前时间
    local now_minute now_hour now_dow
    now_minute=$(date +%M)
    now_hour=$(date +%H)
    now_dow=$(date +%w)  # 0=周日

    # 检查分钟
    if [ "$minute" != "*" ] && [ "$minute" != "$now_minute" ]; then
        return 1
    fi

    # 检查小时
    if [ "$hour" != "*" ] && [ "$hour" != "$now_hour" ]; then
        return 1
    fi

    # 检查星期 (支持: *, 1-5, 1,3,5)
    if [ "$dow" != "*" ]; then
        local matched=0

        # 处理逗号分隔的列表: 1,3,5
        if [[ "$dow" =~ , ]]; then
            IFS=',' read -ra days <<< "$dow"
            for d in "${days[@]}"; do
                d=$(echo "$d" | xargs)  # 去除空格
                if [ "$d" = "$now_dow" ]; then
                    matched=1
                    break
                fi
            done
        # 处理范围: 1-5
        elif [[ "$dow" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local dow_start="${BASH_REMATCH[1]}"
            local dow_end="${BASH_REMATCH[2]}"
            if [ "$now_dow" -ge "$dow_start" ] && [ "$now_dow" -le "$dow_end" ]; then
                matched=1
            fi
        # 处理单个数字: 1
        elif [[ "$dow" =~ ^([0-9]+)$ ]]; then
            if [ "$dow" = "$now_dow" ]; then
                matched=1
            fi
        fi

        if [ "$matched" -eq 0 ]; then
            return 1
        fi
    fi

    return 0
}

# 执行定时任务
execute_task() {
    local task_id="$1"
    local task_type="$2"
    local description="$3"
    local chat_jid="$4"

    log "执行任务: $task_id ($description)"

    local result
    case "$task_type" in
        summary)
            result=$(bash "$ETF_ASSISTANT" summary 2>&1) || true
            ;;
        pending-update)
            result=$(bash "$ETF_ASSISTANT" pending-update 2>&1) || true
            ;;
        dca-check)
            result=$(bash "$ETF_ASSISTANT" dca check 2>&1) || true
            ;;
        *)
            log "未知任务类型: $task_type"
            return 1
            ;;
    esac

    if echo "$result" | grep -qE "错误|失败|Error"; then
        log "任务执行失败: $task_id - $result"
        return 1
    fi

    # 发送结果到用户（通过 IPC）
    if [ -n "$chat_jid" ]; then
        # 转义消息中的特殊字符为 JSON 字符串
        local escaped_result
        escaped_result=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$result" 2>/dev/null || echo '""')
        send_ipc_message "$chat_jid" "$escaped_result"
    fi

    log "任务执行成功: $task_id"
    return 0
}

# 主逻辑
main() {
    log "开始检查定时任务..."

    # 检查 portfolio 文件是否存在
    if [ ! -f "$PORTFOLIO_FILE" ]; then
        log "Portfolio 文件不存在，跳过"
        exit 0
    fi

    # 读取 scheduled_tasks - 使用 JSON 避免特殊字符问题
    local tasks_json
    tasks_json=$(python3 -c "
import json

try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)

    tasks = d.get('scheduled_tasks', {})
    result = []
    for task_id, task in tasks.items():
        if task.get('status') == 'active':
            result.append({
                'id': task_id,
                'type': task.get('type', ''),
                'cron': task.get('cron', ''),
                'description': task.get('description', ''),
                'chatJid': task.get('chatJid', '')
            })
    print(json.dumps(result))
except:
    print('[]')
" 2>/dev/null || echo "[]")

    if [ "$tasks_json" = "[]" ] || [ -z "$tasks_json" ]; then
        log "没有活跃的定时任务"
        exit 0
    fi

    # 获取默认 chat_jid（从 portfolio.json 的顶层 chatJid 字段）
    local default_chat_jid=""
    if [ -f "$PORTFOLIO_FILE" ]; then
        default_chat_jid=$(python3 -c "
import json
try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
        print(d.get('chatJid', ''))
except:
    print('')
" 2>/dev/null)
    fi

    # 遍历检查每个任务 - 使用 Python 解析 JSON 避免管道问题
    local executed=0
    while IFS= read -r task_info; do
        [ -z "$task_info" ] && continue

        # 使用 Python 安全解析 JSON
        task_id=$(echo "$task_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)
        task_type=$(echo "$task_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('type',''))" 2>/dev/null)
        cron=$(echo "$task_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cron',''))" 2>/dev/null)
        description=$(echo "$task_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('description',''))" 2>/dev/null)
        task_chat_jid=$(echo "$task_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('chatJid',''))" 2>/dev/null)

        # 优先使用任务自己的 chat_jid，否则使用默认的
        local final_chat_jid="${task_chat_jid:-$default_chat_jid}"

        if [ -z "$task_id" ] || [ -z "$cron" ]; then
            continue
        fi

        # 检查是否应该现在执行
        if should_run "$cron"; then
            log "任务到期: $task_id ($description)"
            if execute_task "$task_id" "$task_type" "$description" "$final_chat_jid"; then
                executed=$((executed + 1))
            fi
        fi
    done <<< "$tasks_json"

    log "定时任务检查完成, 执行了 $executed 个任务"
}

main "$@"
