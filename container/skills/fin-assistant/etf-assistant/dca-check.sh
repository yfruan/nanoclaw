#!/bin/bash
# DCA Check - 定时检查并执行到期的定投计划
# 由 launchd 每天 9 点调用

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETF_ASSISTANT="$SCRIPT_DIR/etf-assistant.sh"
HOLIDAYS_FILE="$SCRIPT_DIR/holidays.json"

# 默认 portfolio 路径（可通过环境变量覆盖）
PORTFOLIO_FILE="${PORTFOLIO_FILE:-$SCRIPT_DIR/portfolio.json}"

# 日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# 检查是否为交易日
is_trading_day() {
    local date="$1"

    # 周末 (0=周日, 6=周六) - 兼容 Linux 和 macOS
    local day_of_week
    if date -d "$date" +%w >/dev/null 2>&1; then
        # Linux
        day_of_week=$(date -d "$date" +%w)
    else
        # macOS
        day_of_week=$(date -j -f "%Y-%m-%d" "$date" +%w 2>/dev/null || echo "0")
    fi

    if [ "$day_of_week" -eq 0 ] || [ "$day_of_week" -eq 6 ]; then
        return 1  # 非交易日
    fi

    # 检查节假日
    if [ -f "$HOLIDAYS_FILE" ]; then
        local year
        year=$(echo "$date" | cut -d'-' -f1)
        local holidays
        holidays=$(python3 -c "
import json
try:
    with open('$HOLIDAYS_FILE', 'r') as f:
        data = json.load(f)
        year = '$year'
        if year in data:
            print(' '.join(data[year]))
except:
    pass
" 2>/dev/null || echo "")

        if echo "$holidays" | grep -qF -- "$date"; then
            return 1  # 非交易日
        fi
    fi

    return 0  # 交易日
}

# 获取下一个交易日
get_next_trading_day() {
    local current_date="$1"
    local days_to_add=1

    while true; do
        local next_date
        if date -d "$current_date +$days_to_add day" +%Y-%m-%d >/dev/null 2>&1; then
            # Linux
            next_date=$(date -d "$current_date +$days_to_add day" +%Y-%m-%d)
        else
            # macOS
            next_date=$(date -j -v+${days_to_add}d -f "%Y-%m-%d" "$current_date" +%Y-%m-%d 2>/dev/null)
        fi

        if [ -z "$next_date" ]; then
            echo "$current_date"
            return 1
        fi

        if is_trading_day "$next_date"; then
            echo "$next_date"
            return 0
        fi
        days_to_add=$((days_to_add + 1))

        # 防止无限循环
        if [ $days_to_add -gt 30 ]; then
            echo "$current_date"
            return 1
        fi
    done
}

# 执行单个定投
execute_dca() {
    local code="$1"
    local amount="$2"

    log "执行定投: $code 金额=$amount"

    # 调用 etf-assistant add 执行买入
    local result
    result=$(bash "$ETF_ASSISTANT" add "$code" "$amount" 2>&1) || true

    if echo "$result" | grep -qE "成功|已添加|✅"; then
        log "定投成功: $code"
        return 0
    else
        log "定投失败: $code - $result"
        return 1
    fi
}

# 更新下次执行日期
update_next_date() {
    local code="$1"
    local frequency="$2"

    local current_date
    current_date=$(date +%Y-%m-%d)
    local next_date

    case "$frequency" in
        daily)
            next_date=$(get_next_trading_day "$current_date")
            ;;
        weekly)
            next_date=$(get_next_trading_day "$(date -d "$current_date +7 day" +%Y-%m-%d 2>/dev/null || date -j -v+7d -f "%Y-%m-%d" "$current_date" +%Y-%m-%d)")
            ;;
        monthly)
            next_date=$(get_next_trading_day "$(date -d "$current_date +1 month" +%Y-%m-%d 2>/dev/null || date -j -v+1m -f "%Y-%m-%d" "$current_date" +%Y-%m-%d)")
            ;;
        *)
            log "未知频率: $frequency"
            return 1
            ;;
    esac

    # 更新 portfolio.json
    if [ -f "$PORTFOLIO_FILE" ]; then
        local temp_file
        temp_file=$(mktemp)

        # 使用 json 传递参数避免注入
        python3 << EOF > "$temp_file" 2>/dev/null
import json
import sys
import argparse

code = """$code"""
next_date = """$next_date"""
portfolio_file = """$PORTFOLIO_FILE"""

try:
    with open(portfolio_file, 'r') as f:
        d = json.load(f)

    if 'dca' in d and code in d['dca']:
        d['dca'][code]['nextDate'] = next_date
        print(json.dumps(d, ensure_ascii=False))
    else:
        sys.exit(1)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
EOF
        mv "$temp_file" "$PORTFOLIO_FILE" 2>/dev/null || true

        log "已更新 $code 下次执行日期: $next_date"
    fi
}

# 主逻辑
main() {
    local today
    today=$(date +%Y-%m-%d)

    log "开始检查定投计划..."

    # 检查是否为交易日
    if ! is_trading_day "$today"; then
        log "今天不是交易日，跳过"
        exit 0
    fi

    # 检查 portfolio 文件是否存在
    if [ ! -f "$PORTFOLIO_FILE" ]; then
        log "Portfolio 文件不存在: $PORTFOLIO_FILE"
        exit 0
    fi

    # 读取并执行到期的定投计划
    # 使用 JSON 输出避免特殊字符问题
    local dca_json
    dca_json=$(python3 -c "
import json

try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)

    dca = d.get('dca', {})
    result = []
    for code, plan in dca.items():
        if plan.get('status') == 'active':
            result.append({
                'code': code,
                'amount': plan.get('amount', 0),
                'frequency': plan.get('frequency', 'daily'),
                'nextDate': plan.get('nextDate', '')
            })
    print(json.dumps(result))
except:
    print('[]')
" 2>/dev/null || echo "[]")

    # 检查是否有活跃计划
    if [ "$dca_json" = "[]" ] || [ -z "$dca_json" ]; then
        log "没有活跃的定投计划"
        exit 0
    fi

    # 使用 Python 直接执行，避免 bash 管道解析问题
    python3 << 'PYEOF'
import json
import sys
import subprocess
import os
from datetime import datetime, timedelta

dca_json = '''$dca_json'''
today = '''$today'''
portfolio_file = '''$PORTFOLIO_FILE'''
script_dir = '''$SCRIPT_DIR'''

try:
    data = json.loads(dca_json)
except:
    sys.exit(0)

# 计算下一个交易日
def get_next_trading_day(current_date_str, frequency):
    from datetime import datetime, timedelta
    current = datetime.strptime(current_date_str, '%Y-%m-%d')
    days_to_add = 1 if frequency == 'daily' else (7 if frequency == 'weekly' else 30)

    while days_to_add <= 30:
        next_date = current + timedelta(days=days_to_add)
        day_of_week = next_date.weekday()
        # 0=周一, 6=周日 - 跳过周末
        if day_of_week < 5:
            return next_date.strftime('%Y-%m-%d')
        days_to_add += 1
    return current_date_str

# 读取节假日
holidays = set()
holidays_file = os.path.join(script_dir, 'holidays.json')
if os.path.exists(holidays_file):
    try:
        with open(holidays_file, 'r') as f:
            holidays_data = json.load(f)
            year = today[:4]
            if year in holidays_data:
                holidays = set(holidays_data[year])
    except:
        pass

# 更新 portfolio.json 中的 nextDate
def update_next_date(code, new_next_date):
    try:
        with open(portfolio_file, 'r') as f:
            portfolio = json.load(f)
        if 'dca' in portfolio and code in portfolio['dca']:
            portfolio['dca'][code]['nextDate'] = new_next_date
            with open(portfolio_file, 'w') as f:
                json.dump(portfolio, f, ensure_ascii=False, indent=2)
            return True
    except Exception as e:
        print(f"更新nextDate失败: {e}")
    return False

for plan in data:
    code = plan.get('code', '')
    amount = plan.get('amount', 0)
    frequency = plan.get('frequency', 'daily')
    next_date = plan.get('nextDate', '')

    if not code or not next_date:
        continue

    if next_date == today:
        # 执行定投
        print(f"到期计划: {code} 金额={amount}")
        # 调用 etf-assistant add
        result = subprocess.run(
            ['bash', os.path.join(script_dir, 'etf-assistant.sh'), 'add', str(code), str(amount)],
            capture_output=True, text=True, timeout=30
        )
        if '成功' in result.stdout or '已添加' in result.stdout or '✅' in result.stdout:
            print(f"{code} 定投成功")
        else:
            print(f"{code} 定投失败: {result.stdout[:100]}")

        # 无论成功或失败，都更新下次执行日期
        new_next = get_next_trading_day(today, frequency)
        # 跳过节假日
        while new_next in holidays:
            from datetime import datetime
            next_dt = datetime.strptime(new_next, '%Y-%m-%d') + timedelta(days=1)
            new_next = next_dt.strftime('%Y-%m-%d')

        update_next_date(code, new_next)
        print(f"{code} 下次执行日期已更新: {new_next}")
PYEOF

    log "定投检查完成"
}

main "$@"
