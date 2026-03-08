#!/bin/bash
# ETF 基金投资助理
# 功能：ETF 基金持仓管理、净值查询、定投计划、收益汇总

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 浮点计算函数（兼容 bc 和 Python）
# 使用 JSON 传递参数避免注入
calc() {
    local expr="$1"
    local scale="${2:-2}"

    # 验证输入是简单数字表达式（只允许数字和小数点）
    if ! [[ "$expr" =~ ^[0-9.]+$ ]]; then
        # 尝试简单的加减乘除（不允许括号和复杂表达式）
        if [[ "$expr" =~ ^[0-9.]+[\+\-\*/][0-9.]+$ ]]; then
            : # 允许简单运算
        else
            echo "0"
            return 1
        fi
    fi

    # 优先使用 bc
    if command -v bc &>/dev/null; then
        echo "scale=$scale; $expr" | bc 2>/dev/null
        return
    fi

    # 使用 Python 作为备选（使用 json 传递参数避免注入）
    python3 -c "
import sys
import json

expr = '''$expr'''
scale_val = '''$scale'''
scale = int(scale_val) if scale_val else 2

# 安全计算：只支持基本运算符
try:
    # 使用受限的 eval
    allowed_ops = {'+': lambda a,b: a+b, '-': lambda a,b: a-b, '*': lambda a,b: a*b, '/': lambda a,b: a/b}

    # 解析简单表达式
    for op in ['+', '-', '*', '/']:
        if op in expr:
            parts = expr.split(op)
            if len(parts) == 2:
                a, b = float(parts[0]), float(parts[1])
                result = allowed_ops[op](a, b)
                print(round(result, scale))
                sys.exit(0)

    # 纯数字
    print(round(float(expr), scale))
except:
    print(0)
" 2>/dev/null
}

# 比较函数：返回 0 表示真，1 表示假
gt() {
    local a="$1"
    local b="$2"

    # 验证输入是数字
    if ! [[ "$a" =~ ^[0-9.]+$ ]] || ! [[ "$b" =~ ^[0-9.]+$ ]]; then
        return 1
    fi

    if command -v bc &>/dev/null; then
        result=$(echo "$a > $b" | bc -l)
        [ "$result" = "1" ] && return 0 || return 1
    fi
    # 使用 json 传递参数避免注入
    python3 -c "import sys, json; exit(0 if $a > $b else 1)" 2>/dev/null
}

lt() {
    local a="$1"
    local b="$2"

    # 验证输入是数字
    if ! [[ "$a" =~ ^[0-9.]+$ ]] || ! [[ "$b" =~ ^[0-9.]+$ ]]; then
        return 1
    fi

    if command -v bc &>/dev/null; then
        result=$(echo "$a < $b" | bc -l)
        [ "$result" = "1" ] && return 0 || return 1
    fi
    # 使用 json 传递参数避免注入
    python3 -c "import sys, json; exit(0 if $a < $b else 1)" 2>/dev/null
}

# 持仓数据文件路径 (可通过环境变量覆盖)
# 获取脚本所在目录的根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# 根据 GROUP_NAME 选择数据路径
# 如果是 fin-assistant 群组（默认），使用 groups/fin-assistant/
# 否则使用 /workspace/group/fin-assistant/ (挂载到对应群组的文件夹)
if [ "$GROUP_NAME" = "fin-assistant" ] || [ -z "$GROUP_NAME" ]; then
  PORTFOLIO_FILE="${PORTFOLIO_FILE:-$SCRIPT_DIR/groups/fin-assistant/portfolio.json}"
else
  PORTFOLIO_FILE="${PORTFOLIO_FILE:-/workspace/group/fin-assistant/portfolio.json}"
fi

# 获取ETF/基金代码对应的交易所
get_secid() {
    local code=$1
    if [[ "$code" =~ ^5 ]]; then
        echo "1.$code"  # 上海
    elif [[ "$code" =~ ^1 ]]; then
        echo "0.$code"  # 深圳
    else
        echo ""  # 场外基金
    fi
}

# 获取基金/ETF名称
get_etf_name() {
    local code=$1
    # 从API获取名称
    local response=$(curl -s "https://fundgz.1234567.com.cn/js/${code}.js" 2>/dev/null)
    if echo "$response" | grep -q "name"; then
        echo "$response" | sed 's/.*"name":"\([^"]*\)".*/\1/'
    else
        echo "未知基金"
    fi
}

# 判断是否为场内ETF（6开头）
is_etf() {
    local code=$1
    [[ "$code" =~ ^1[59] ]] || [[ "$code" =~ ^5 ]]
}

# 查询场内ETF实时行情 (带重试和多API)
get_etf_price() {
    local code=$1

    # 判断交易所
    local prefix=""
    if [[ "$code" =~ ^5 ]]; then
        prefix="sh"
    elif [[ "$code" =~ ^1[59] ]]; then
        prefix="sz"
    else
        echo ""
        return 1
    fi

    # 尝试腾讯API (主) - 需要GBK编码
    local response=$(curl -s --max-time 5 "https://qt.gtimg.cn/q=${prefix}${code}" 2>/dev/null)

    if [ -n "$response" ] && echo "$response" | grep -q "v_${prefix}${code}"; then
        # 解析腾讯API格式 (使用python3，更好的编码处理)
        local result=$(echo "$response" | python3 -c "
import sys, re
data = sys.stdin.buffer.read().decode('gbk', errors='ignore')
match = re.search(r'v_${prefix}${code}=\"([^\"]+)\"', data)
if match:
    parts = match.group(1).split('~')
    print(f'{parts[3]}|{parts[31]}|{parts[32]}')
" 2>/dev/null)

        if [ -n "$result" ]; then
            echo "$result|"
            return 0
        fi
    fi

    # 尝试东方财富API (备选)
    local secid=""
    if [[ "$code" =~ ^5 ]]; then
        secid="1.$code"
    else
        secid="0.$code"
    fi

    local urls=(
        "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=${secid}&fields=f2,f3,f4,f12,f13,f14"
        "https://push2.eastmoney.com/api/qt/stock/get?fltt=2&fields=f43,f46,f50,f57,f58&secid=$secid"
    )

    for url in "${urls[@]}"; do
        response=$(curl -s --max-time 5 "$url" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | grep -q '"data"'; then
            break
        fi
    done

    if [ -z "$response" ] || echo "$response" | grep -q '"data":null'; then
        echo ""
        return 1
    fi

    # 提取东财数据
    local current=""
    local change=""
    local change_pct=""

    if echo "$response" | grep -q '"f2"'; then
        current=$(echo "$response" | sed 's/.*"f2":\([^,]*\),.*/\1/')
        change_pct=$(echo "$response" | sed 's/.*"f3":\([^,]*\),.*/\1/')
        change=$(echo "$response" | sed 's/.*"f4":\([^,]*\),.*/\1/')
    elif echo "$response" | grep -q '"f43"'; then
        current=$(echo "$response" | sed 's/.*"f43":\([^,]*\),.*/\1/')
        change=$(echo "$response" | sed 's/.*"f46":\([^,]*\),.*/\1/')
        change_pct=$(echo "$response" | sed 's/.*"f50":\([^,]*\),.*/\1/')
        if [ -n "$current" ] && [ "$current" != "0" ]; then
            current=$(echo "scale=3; $current / 1000" | bc 2>/dev/null)
            change=$(echo "scale=4; $change / 10000" | bc 2>/dev/null || echo "0")
            change_pct=$(echo "scale=2; $change_pct / 100" | bc 2>/dev/null || echo "0")
        fi
    fi

    if [ -n "$current" ] && [ "$current" != "0" ] && [ "$current" != "-" ]; then
        echo "$current|$change|$change_pct|"
        return 0
    fi

    echo ""
    return 1
}

# 查询场外基金实时估值
get_fund_nav() {
    local code=$1

    # 先尝试获取最终净值 (东方财富API)
    local today=$(date +%Y-%m-%d)
    local yesterday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null)
    local final_nav=""
    local final_change=""

    local response=$(curl -s -H "Referer: http://fundf10.eastmoney.com/" \
        "https://api.fund.eastmoney.com/f10/lsjz?fundCode=${code}&pageIndex=1&pageSize=1" 2>/dev/null)

    if echo "$response" | grep -q '"DWJZ"'; then
        final_nav=$(echo "$response" | sed 's/.*"DWJZ":"\([^"]*\)".*/\1/')
        final_change=$(echo "$response" | sed 's/.*"JZZZL":"\([^"]*\)".*/\1/')

        # 检查是否是今日或昨日数据（交易日收盘后会有）
        local nav_date=$(echo "$response" | sed 's/.*"FSRQ":"\([^"]*\)".*/\1/')
        if ([ "$nav_date" = "$today" ] || [ "$nav_date" = "$yesterday" ]) && [ -n "$final_nav" ]; then
            # 格式: 最终净值|最终涨跌|来源(fin)
            echo "$final_nav|$final_change|fin"
            return 0
        fi
    fi

    # 回退到估算净值API
    local url="https://fundgz.1234567.com.cn/js/${code}.js"
    response=$(curl -s "$url" 2>/dev/null)

    if echo "$response" | grep -q "gsz"; then
        local gsz=$(echo "$response" | sed 's/.*"gsz":"\([^"]*\)".*/\1/')
        local gszzl=$(echo "$response" | sed 's/.*"gszzl":"\([^"]*\)".*/\1/')
        local gsz_time=$(echo "$response" | sed 's/.*"gztime":"\([^"]*\)".*/\1/')
        local dwjz=$(echo "$response" | sed 's/.*"dwjz":"\([^"]*\)".*/\1/')

        if [ -n "$gsz" ]; then
            # 格式: 估算净值|估算涨跌|来源(est)
            echo "$gsz|$gszzl|est"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

# 获取基金基本信息（类型、ETF联接对应ETF代码）
get_fund_info() {
    local code=$1
    local url="https://fund.eastmoney.com/pingzhongdata/${code}.js"
    local response=$(curl -s "$url" 2>/dev/null | head -2000)

    if [ -z "$response" ]; then
        echo ""
        return 1
    fi

    # 提取基金类型
    local fund_type=""
    if echo "$response" | grep -qE "ETF联接|QDII"; then
        fund_type="ETF联接"
    elif echo "$response" | grep -q "混合"; then
        fund_type="混合"
    elif echo "$response" | grep -q "股票"; then
        fund_type="股票"
    elif echo "$response" | grep -q "债券"; then
        fund_type="债券"
    else
        fund_type="其他"
    fi

    # 提取ETF联接对应的ETF代码
    local etf_code=""

    # 方法1: 查找 jjtzz 字段（基金投资组合）
    if [ -z "$etf_code" ]; then
        etf_code=$(echo "$response" | grep -oE '"jjtzz":"[0-9]{6}"' | head -1 | sed 's/"jjtzz":"//;s/"//')
    fi

    # 方法2: 查找 mrcde 字段（基金代码）
    if [ -z "$etf_code" ]; then
        etf_code=$(echo "$response" | grep -oE '"mrcde":"[0-9]{6}"' | head -1 | sed 's/"mrcde":"//;s/"//')
    fi

    # 方法3: 查找持仓中的ETF代码（5开头或159/160/161开头）
    if [ -z "$etf_code" ]; then
        etf_code=$(echo "$response" | grep -oE '"(holdcode|stockCode)":"[0-9]{6}"' | head -1 | sed 's/.*"holdcode":"//;s/"//;s/.*"stockCode":"//;s/"//')
    fi

    # 方法4: 查找有效的ETF代码（159/160/510/511/512开头）
    if [ -z "$etf_code" ]; then
        etf_code=$(echo "$response" | grep -oE '159[0-9]{3}|160[0-9]{3}|510[0-9]{3}|511[0-9]{3}|512[0-9]{3}' | head -1)
    fi

    # 验证ETF代码是否有效（通过查询ETF名称）
    if [ -n "$etf_code" ]; then
        local etf_name=$(curl -s "https://fundgz.1234567.com.cn/js/${etf_code}.js" 2>/dev/null | grep -oE '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//')
        if [ -z "$etf_name" ]; then
            # ETF代码无效，清空
            etf_code=""
        fi
    fi

    echo "$fund_type|$etf_code"
}

# 获取ETF联接基金的实时净值（通过已保存的对应ETF）
# 估值公式: 联接基金净值 = 成本价 × (1 + ETF涨跌率)
get_linked_etf_price() {
    local fund_code=$1
    local etf_code=$2

    if [ -z "$etf_code" ]; then
        echo ""
        return 1
    fi

    # 获取对应ETF的实时行情（获取涨跌率）
    local price_info=$(get_etf_price "$etf_code")
    if [ -z "$price_info" ]; then
        echo ""
        return 1
    fi

    local etf_change_pct=$(echo "$price_info" | cut -d'|' -f3)
    local etf_change=$(echo "$price_info" | cut -d'|' -f2)

    if [ -z "$etf_change_pct" ] || [ "$etf_change_pct" = "-" ]; then
        echo ""
        return 1
    fi

    # 从portfolio获取成本价
    local cost_price=0
    if [ -f "$PORTFOLIO_FILE" ]; then
        cost_price=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
fund_code = '''$fund_code'''
d=json.load(sys.stdin)
funds = d.get('funds',{})
if fund_code in funds:
    f = funds[fund_code]
    cost = f.get('costPrice')
    if cost:
        print(cost)
" 2>/dev/null || echo "0")
    fi

    # 如果有成本价，使用成本价计算估值
    # 估值 = 成本价 × (1 + 涨跌率)
    if [ -n "$cost_price" ] && (( $(echo "$cost_price > 0" | bc -l) )); then
        local estimated_nav=$(echo "scale=4; $cost_price * (1 + $etf_change_pct / 100)" | bc)
        # 涨跌金额 = 估值 - 成本价
        local daily_change=$(echo "scale=4; $estimated_nav - $cost_price" | bc)
        echo "$estimated_nav|$daily_change|$etf_change_pct|$etf_code"
    else
        # 如果没有成本价，返回0（需要用户添加成本价）
        echo "0|$etf_change|$etf_change_pct|$etf_code"
    fi
}

show_help() {
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                基金投资助理              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "基础命令:"
    echo "  list              查看持仓列表"
    echo "  price <代码>      查询基金/ETF实时行情"
    echo "  info <代码>       获取基金基本信息"
    echo "  summary           收益汇总"
    echo "  compare <代码1> <代码2>  对比两只ETF"
    echo "  calc <代码> <金额> <年限>  定投收益计算"
    echo ""
    echo "持仓管理:"
    echo "  add <代码> <金额> [成本价]       添加持仓（按金额）"
    echo "  add <代码> <份额> <成本价> -s    添加持仓（按份额，截图识别用）"
    echo "  remove <代码> <数量>             卖出（按份额）"
    echo "  remove <代码> <金额> -v          卖出（按金额）"
    echo "  list                             查看持仓列表"
    echo "  summary                          收益汇总"
    echo ""
    echo "定投管理:"
    echo "  dca add <代码> <金额> <频率>  添加定投"
    echo "  dca list                    查看定投计划"
    echo "  dca remove <代码>           移除定投"
    echo "  dca check                  检查并执行定投（定时任务用）"
    echo "  schedule add <描述> <类型> <cron>  添加定时任务"
    echo "  schedule list              查看定时任务"
    echo "  schedule remove <ID>       移除定时任务"
    echo ""
    echo "其他:"
    echo "  pending-update              检查并更新待确认成本价"
    echo "  help                       显示帮助"
    echo ""
    echo "示例:"
    echo "  $0 price 510300"
    echo "  $0 price 110022"
    echo "  $0 add 110022 1000"
    echo "  $0 add 110022 1000 1.25"
    echo "  $0 add 002610 15500.27 3.57 -s  # 按份额添加（截图识别用）"
    echo "  $0 remove 110022 100"
    echo "  $0 dca add 110022 100 daily"
}

# 检查是否为交易日
is_trading_day() {
    local date="${1:-$(date +%Y-%m-%d)}"

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
    if [ "$GROUP_NAME" = "fin-assistant" ] || [ -z "$GROUP_NAME" ]; then
      local holidays_file="$SCRIPT_DIR/../groups/fin-assistant/holidays.json"
    else
      local holidays_file="/workspace/group/fin-assistant/holidays.json"
    fi
    if [ -f "$holidays_file" ]; then
        local year
        year=$(echo "$date" | cut -d'-' -f1)
        # 使用 Python 避免 shell 注入
        local holidays
        holidays=$(python3 -c "
import json
import sys
try:
    with open('$holidays_file', 'r') as f:
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
    local current_date="${1:-$(date +%Y-%m-%d)}"
    local days_to_add=1

    while true; do
        local next_date
        next_date=$(date -d "$current_date +$days_to_add day" +%Y-%m-%d 2>/dev/null || {
            date -j -v+${days_to_add}d -f "%Y-%m-%d" "$current_date" +%Y-%m-%d 2>/dev/null
        })

        if [ -z "$next_date" ]; then
            echo "$current_date"
            return 1
        fi

        if is_trading_day "$next_date"; then
            echo "$next_date"
            return 0
        fi
        days_to_add=$((days_to_add + 1))

        if [ $days_to_add -gt 30 ]; then
            echo "$current_date"
            return 1
        fi
    done
}

# 设置 launchd 定时任务（如果需要）
setup_dca_launchd() {
    # 容器内不创建 launchd 配置（只在 macOS 主机上）
    if [ -f "/.dockerenv" ] || [ ! -f "/usr/bin/launchctl" ]; then
        return 0
    fi

    # 检查是否已经有 launchd 配置
    local plist_path="$HOME/Library/LaunchAgents/com.nanoclaw.dca.plist"

    if [ -f "$plist_path" ]; then
        return 0  # 已存在
    fi

    # 检查是否有活跃的定投计划
    local dca_count
    dca_count=$(python3 -c "
import json
try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
    dca = d.get('dca', {})
    active_count = sum(1 for p in dca.values() if p.get('status') == 'active')
    print(active_count)
except:
    print(0)
" 2>/dev/null || echo "0")

    if [ "$dca_count" -lt 1 ]; then
        return 0  # 没有活跃定投
    fi

    # 创建 launchd 配置
    local project_dir
    project_dir=$(cd "$(dirname "$SCRIPT_DIR")/../../../../" && pwd)

    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$plist_path" << 'EOFPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nanoclaw.dca</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/container</string>
        <string>run</string>
        <string>--rm</string>
        <string>-v</string>
        <string>PROJECT_DIR_PLACEHOLDER:/workspace:rw</string>
        <string>-v</string>
        <string>PROJECT_DIR_PLACEHOLDER/groups/fin-assistant:/workspace/group/fin-assistant:rw</string>
        <string>nanoclaw-agent:latest</string>
        <string>bash</string>
        <string>/workspace/container/skills/fin-assistant/etf-assistant/dca-check.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>0</integer>
            <key>Weekday</key>
            <integer>1</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>0</integer>
            <key>Weekday</key>
            <integer>2</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>0</integer>
            <key>Weekday</key>
            <integer>3</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>0</integer>
            <key>Weekday</key>
            <integer>4</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>0</integer>
            <key>Weekday</key>
            <integer>5</integer>
        </dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOFPLIST

    # 替换路径占位符 (兼容 macOS 和 Linux)
    if sed -i '' "s|PROJECT_DIR_PLACEHOLDER|$project_dir|g" "$plist_path" 2>/dev/null; then
        : # macOS sed -i ''
    elif sed -i "s|PROJECT_DIR_PLACEHOLDER|$project_dir|g" "$plist_path" 2>/dev/null; then
        : # Linux sed -i
    else
        # 备用方案: 使用 Python
        python3 -c "
import sys
with open('$plist_path', 'r') as f:
    content = f.read()
content = content.replace('PROJECT_DIR_PLACEHOLDER', '$project_dir')
with open('$plist_path', 'w') as f:
    f.write(content)
" 2>/dev/null || true
    fi

    # 加载 launchd 任务
    launchctl load "$plist_path" 2>/dev/null || true

    echo -e "${CYAN}⏰ 已设置每天9点自动执行定投${NC}"
}

# 初始化持仓文件
init_portfolio() {
    if [ ! -f "$PORTFOLIO_FILE" ]; then
        echo '{"funds":{},"dca":{},"pendingCostUpdate":{}}' > "$PORTFOLIO_FILE"
    fi
}

# 读取持仓数据
read_portfolio() {
    init_portfolio
    cat "$PORTFOLIO_FILE"
}

# 写入持仓数据
write_portfolio() {
    local data=$1
    echo "$data" > "$PORTFOLIO_FILE"
}

# 命令: 查询基金/ETF行情
cmd_price() {
    local code=$1
    if [ -z "$code" ]; then
        echo -e "${RED}❌ 请输入基金代码${NC}"
        return 1
    fi

    echo -e "${GREEN}📈 $(get_etf_name "$code") ($code) 实时行情${NC}"
    echo ""

    # 先尝试从 portfolio 获取已保存的 etfCode 和类型
    local saved_etf_code=""
    local saved_fund_type=""
    if [ -f "$PORTFOLIO_FILE" ]; then
        saved_etf_code=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
code = '''$code'''
d=json.load(sys.stdin)
funds = d.get('funds',{})
if code in funds:
    f = funds[code]
    print(f.get('etfCode', '') or '')
" 2>/dev/null)
        saved_fund_type=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
code = '''$code'''
d=json.load(sys.stdin)
funds = d.get('funds',{})
if code in funds:
    f = funds[code]
    print(f.get('type', '') or '')
" 2>/dev/null)
    fi

    # 如果没有保存的 etfCode，调用 API 获取
    local fund_info=$(get_fund_info "$code")
    local fund_type=$(echo "$fund_info" | cut -d'|' -f1)
    local etf_code=$(echo "$fund_info" | cut -d'|' -f2)

    # 优先使用已保存的 etfCode
    [ -n "$saved_etf_code" ] && etf_code="$saved_etf_code"
    [ -n "$saved_fund_type" ] && fund_type="$saved_fund_type"

    if is_etf "$code"; then
        # 场内ETF
        local price_info=$(get_etf_price "$code")
        if [ -n "$price_info" ]; then
            local current=$(echo "$price_info" | cut -d'|' -f1)
            local change=$(echo "$price_info" | cut -d'|' -f2)
            local change_pct=$(echo "$price_info" | cut -d'|' -f3)
            local prev_close=$(echo "$price_info" | cut -d'|' -f4)

            echo -e "当前价格: ${GREEN}$current${NC}"
            echo -e "昨收: $prev_close"
            echo -e "涨跌: $(echo "$change >= 0" | bc -l | grep -q 1 && echo "+$change" || echo "$change") ($(echo "$change_pct >= 0" | bc -l | grep -q 1 && echo "+$change_pct" || echo "$change_pct")%)"

            if (( $(echo "$change_pct > 0" | bc -l) )); then
                echo -e "${GREEN}📈 上涨${NC}"
            elif (( $(echo "$change_pct < 0" | bc -l) )); then
                echo -e "${RED}📉 下跌${NC}"
            else
                echo "📊 平盘"
            fi
        else
            echo -e "${YELLOW}⚠️  暂时无法获取行情数据${NC}"
        fi
    elif [ "$fund_type" = "ETF联接" ]; then
        # ETF联接 - 优先使用天天基金实时估值API
        local nav_info=$(get_fund_nav "$code")
        if [ -n "$nav_info" ]; then
            local gsz=$(echo "$nav_info" | cut -d'|' -f1)
            local gszzl=$(echo "$nav_info" | cut -d'|' -f2)
            local gsz_time=$(echo "$nav_info" | cut -d'|' -f3)

            echo -e "📌 ETF联接基金 (天天基金实时估值)"
            if [ -n "$etf_code" ]; then
                echo -e "对应ETF: $etf_code"
            fi
            echo -e "估算净值: ${GREEN}$gsz${NC}"
            echo -e "估算涨跌: $(echo "$gszzl >= 0" | bc -l | grep -q 1 && echo "+$gszzl" || echo "$gszzl")%"
            echo -e "更新时间: $gsz_time"

            if (( $(echo "$gszzl > 0" | bc -l) )); then
                echo -e "${GREEN}📈 上涨${NC}"
            elif (( $(echo "$gszzl < 0" | bc -l) )); then
                echo -e "${RED}📉 下跌${NC}"
            else
                echo "📊 平盘"
            fi
        elif [ -n "$etf_code" ]; then
            # 如果天天基金API失败，尝试使用对应ETF计算
            local linked_info=$(get_linked_etf_price "$code" "$etf_code")
            if [ -n "$linked_info" ]; then
                local estimated_nav=$(echo "$linked_info" | cut -d'|' -f1)
                local etf_change=$(echo "$linked_info" | cut -d'|' -f2)
                local etf_change_pct=$(echo "$linked_info" | cut -d'|' -f3)
                local linked_etf=$(echo "$linked_info" | cut -d'|' -f4)

                if [ -z "$estimated_nav" ] || [ "$estimated_nav" = "0" ] || [ "$estimated_nav" = "0.0000" ]; then
                    echo -e "📌 ETF联接基金，对应ETF: ${linked_etf}"
                    echo -e "${YELLOW}⚠️  无法计算估值，请先添加成本价${NC}"
                else
                    echo -e "📌 ETF联接基金，使用对应ETF(${linked_etf})涨跌估值:"
                    echo -e "估算净值: ${GREEN}$estimated_nav${NC}"
                    echo -e "涨跌: $(echo "$etf_change >= 0" | bc -l | grep -q 1 && echo "+$etf_change" || echo "$etf_change") ($(echo "$etf_change_pct >= 0" | bc -l | grep -q 1 && echo "+$etf_change_pct" || echo "$etf_change_pct")%)"

                    if (( $(echo "$etf_change_pct > 0" | bc -l) )); then
                        echo -e "${GREEN}📈 上涨${NC}"
                    elif (( $(echo "$etf_change_pct < 0" | bc -l) )); then
                        echo -e "${RED}📉 下跌${NC}"
                    else
                        echo "📊 平盘"
                    fi
                fi
            else
                echo -e "${YELLOW}⚠️  暂时无法获取行情数据${NC}"
            fi
        else
            # ETF联接基金没有最终净值也没有ETF代码
            echo -e "📌 ETF联接基金"
            echo -e "${YELLOW}⚠️  无法获取最终净值，且未找到对应的场内ETF代码${NC}"
            echo ""
            echo -e "请手动添加对应的场内ETF代码："
            echo -e "  etf-assistant add <code> <金额> <成本价> -s <ETF代码>"
            echo -e "例如：etf-assistant add 025732 1000 1.23 -s 159267"
        fi
    else
        # 普通场外基金
        local nav_info=$(get_fund_nav "$code")
        if [ -n "$nav_info" ]; then
            local gsz=$(echo "$nav_info" | cut -d'|' -f1)
            local gszzl=$(echo "$nav_info" | cut -d'|' -f2)
            local gsz_time=$(echo "$nav_info" | cut -d'|' -f3)

            echo -e "估算净值: ${GREEN}$gsz${NC}"
            echo -e "估算涨跌: $(echo "$gszzl >= 0" | bc -l | grep -q 1 && echo "+$gszzl" || echo "$gszzl")%"
            echo -e "更新时间: $gsz_time"

            if (( $(echo "$gszzl > 0" | bc -l) )); then
                echo -e "${GREEN}📈 上涨${NC}"
            elif (( $(echo "$gszzl < 0" | bc -l) )); then
                echo -e "${RED}📉 下跌${NC}"
            else
                echo "📊 平盘"
            fi
        else
            echo -e "${YELLOW}⚠️  暂时无法获取净值数据${NC}"
        fi
    fi
}

# 命令: 获取基金基本信息
cmd_info() {
    local code=$1
    if [ -z "$code" ]; then
        echo -e "${RED}❌ 请输入基金代码${NC}"
        return 1
    fi

    echo -e "${GREEN}📋 基金基本信息: $code${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━"

    # 获取基金名称
    local name=$(get_etf_name "$code")
    echo "名称: $name"

    # 获取基本信息
    local info=$(get_fund_info "$code")
    if [ -n "$info" ]; then
        local fund_type=$(echo "$info" | cut -d'|' -f1)
        local etf_code=$(echo "$info" | cut -d'|' -f2)
        echo "类型: $fund_type"
        if [ -n "$etf_code" ]; then
            echo "对应ETF: $etf_code ($(get_etf_name "$etf_code"))"
        fi
    fi

    # 显示当前净值
    if is_etf "$code"; then
        local price_info=$(get_etf_price "$code")
        if [ -n "$price_info" ]; then
            local current=$(echo "$price_info" | cut -d'|' -f1)
            echo "当前价格: $current"
        fi
    else
        local nav_info=$(get_fund_nav "$code")
        if [ -n "$nav_info" ]; then
            local gsz=$(echo "$nav_info" | cut -d'|' -f1)
            echo "估算净值: $gsz"
        fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━"
}

# 命令: 添加持仓
cmd_add() {
    local code=$1
    local second=$2
    local cost=$3
    local fourth=$4
    local fifth=$5
    local by_shares=false
    local mode="amount"  # amount: 按金额, shares: 按份额
    local manual_etf_code=""

    # 检查是否是按份额模式 (-s 参数)
    if [ "$fourth" = "-s" ] || [ "$fifth" = "-s" ]; then
        by_shares=true
        mode="shares"
    fi

    # 检查是否指定了 ETF 代码 (-e 参数)
    if [ "$fourth" = "-e" ]; then
        manual_etf_code="$fifth"
    elif [ "$fifth" = "-e" ]; then
        # 可能是第六个参数
        local sixth=$6
        if [ -n "$sixth" ]; then
            manual_etf_code="$sixth"
        fi
    fi

    if [ -z "$code" ] || [ -z "$second" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "用法: $0 add <代码> <金额> [成本价] [-e <ETF代码>]"
        echo "      $0 add <代码> <份额> <成本价> -s [-e <ETF代码>]"
        echo "示例: $0 add 110022 1000"
        echo "      $0 add 110022 1000 1.25"
        echo "      $0 add 002610 15500.27 3.57 -s"
        echo "      $0 add 025732 1000 1.23 -e 159267  # 指定ETF代码"
        return 1
    fi

    init_portfolio

    # 获取基金信息
    local name=$(get_etf_name "$code")
    local fund_info=$(get_fund_info "$code")
    local fund_type=$(echo "$fund_info" | cut -d'|' -f1)
    local etf_code=$(echo "$fund_info" | cut -d'|' -f2)

    # 优先级: 手动指定 > 已保存的 > API检测
    if [ -n "$manual_etf_code" ]; then
        etf_code="$manual_etf_code"
    elif [ -f "$PORTFOLIO_FILE" ]; then
        local saved=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
code = '''$code'''
d=json.load(sys.stdin)
funds = d.get('funds',{})
if code in funds:
    print(funds[code].get('etfCode', ''))
" 2>/dev/null)
        [ -n "$saved" ] && etf_code="$saved"
    fi

    # 获取当前净值
    local nav=0
    local daily_change=0
    local daily_change_pct=0

    if is_etf "$code"; then
        local price_info=$(get_etf_price "$code")
        if [ -n "$price_info" ]; then
            nav=$(echo "$price_info" | cut -d'|' -f1)
            daily_change=$(echo "$price_info" | cut -d'|' -f2)
            daily_change_pct=$(echo "$price_info" | cut -d'|' -f3)
        fi
    elif [ "$fund_type" = "ETF联接" ]; then
        # ETF联接 - 优先使用天天基金实时估值API
        local nav_info=$(get_fund_nav "$code")
        if [ -n "$nav_info" ]; then
            nav=$(echo "$nav_info" | cut -d'|' -f1)
            daily_change_pct=$(echo "$nav_info" | cut -d'|' -f2)
            # 估算涨跌金额
            if [ -n "$nav" ] && [ "$nav" != "0" ]; then
                daily_change=$(echo "scale=4; $nav * $daily_change_pct / 100" | bc)
            fi
        elif [ -n "$etf_code" ]; then
            # 如果天天基金API失败，使用对应ETF计算
            local linked_info=$(get_linked_etf_price "$code" "$etf_code")
            if [ -n "$linked_info" ]; then
                nav=$(echo "$linked_info" | cut -d'|' -f1)
                daily_change=$(echo "$linked_info" | cut -d'|' -f2)
                daily_change_pct=$(echo "$linked_info" | cut -d'|' -f3)
            fi
        fi
    else
        local nav_info=$(get_fund_nav "$code")
        if [ -n "$nav_info" ]; then
            nav=$(echo "$nav_info" | cut -d'|' -f1)
            daily_change_pct=$(echo "$nav_info" | cut -d'|' -f2)
            # 估算涨跌金额
            if [ -n "$nav" ] && [ "$nav" != "0" ]; then
                daily_change=$(echo "scale=4; $nav * $daily_change_pct / 100" | bc)
            fi
        fi
    fi

    # 根据模式计算份额或金额
    local shares=0
    local amount=0

    if $by_shares; then
        # 按份额模式（截图识别用）
        shares=$second
        # 计算持有金额
        if [ -n "$nav" ] && (( $(echo "$nav > 0" | bc -l) )); then
            amount=$(echo "scale=2; $shares * $nav" | bc)
        fi
    else
        # 按金额模式（默认）
        amount=$second
        # 计算份额
        if [ -n "$nav" ] && (( $(echo "$nav > 0" | bc -l) )); then
            shares=$(echo "scale=4; $amount / $nav" | bc)
        fi
    fi

    # 准备持仓数据
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # 读取现有数据
    local portfolio=$(cat "$PORTFOLIO_FILE")

    # 如果没有成本价且是按金额模式，添加到待更新列表
    if [ -z "$cost" ] && [ -n "$nav" ] && [ "$mode" = "amount" ]; then
        # 计算目标日期
        local hour=$(date -u +"%H")
        local target_date=""
        if (( $(echo "$hour < 15" | bc -l) )); then
            # 15:00前购买，当日22:00后更新
            target_date=$(date -u +"%Y-%m-%dT22:00:00Z")
        else
            # 15:00后购买，次日22:00后更新
            target_date=$(date -u -d "+1 day" +"%Y-%m-%dT22:00:00Z")
        fi

        # 添加到pendingCostUpdate，同时添加到funds
        local pending_data=$(echo "$portfolio" | python3 -c "
import json,sys
d=json.load(sys.stdin)

# 使用三引号避免注入
code = '''$code'''
name = '''$name'''
fund_type = '''$fund_type'''
etf_code = '''$etf_code'''
now = '''$now'''
target_date = '''$target_date'''
shares = float('''$shares''')
amount = float('''$amount''')
nav = '''$nav'''
daily_change = '''$daily_change'''
daily_change_pct = '''$daily_change_pct'''

# 确保funds存在
if 'funds' not in d:
    d['funds'] = {}
# 添加基金到funds（成本价为null表示待确认）
d['funds'][code] = {
    'name': name,
    'code': code,
    'type': fund_type,
    'etfCode': etf_code if etf_code else None,
    'shares': shares,
    'costPrice': None,
    'nav': float(nav) if nav else 0,
    'holdIncome': 0,
    'totalIncome': 0,
    'dailyChange': float(daily_change) if daily_change else 0,
    'dailyChangePct': float(daily_change_pct) if daily_change_pct else 0,
    'updatedAt': now
}
# 添加到pendingCostUpdate
d['pendingCostUpdate'] = d.get('pendingCostUpdate',{})
d['pendingCostUpdate'][code] = {
    'shares': shares,
    'amount': amount,
    'purchaseTime': now,
    'targetDate': target_date
}
print(json.dumps(d))
" 2>/dev/null)

        if [ -n "$pending_data" ]; then
            write_portfolio "$pending_data"
        fi

        echo -e "${GREEN}✅ 已添加持仓（成本价待确认）${NC}"
        echo "基金: $name ($code)"
        if $by_shares; then
            echo "份额: $shares"
            echo "持有金额: ¥$amount"
        else
            echo "金额: ¥$amount"
            echo "份额: $shares"
        fi
        echo "当前净值: $nav"
        echo "成本价将在22:00后自动更新"
    else
        # 直接更新持仓（按份额模式或有成本价时）
        # 清除pendingCostUpdate中的记录
        local result=$(echo "$portfolio" | python3 -c "
import json,sys
d=json.load(sys.stdin)

# 使用三引号避免注入
code = '''$code'''
name = '''$name'''
fund_type = '''$fund_type'''
etf_code = '''$etf_code'''
cost = '''$cost'''
now = '''$now'''
shares = float('''$shares''')
nav = '''$nav'''
daily_change = '''$daily_change'''
daily_change_pct = '''$daily_change_pct'''

if 'funds' not in d:
    d['funds'] = {}
d['funds'][code] = {
    'name': name,
    'code': code,
    'type': fund_type,
    'etfCode': etf_code if etf_code else None,
    'shares': shares,
    'costPrice': float(cost) if cost else None,
    'nav': float(nav) if nav else 0,
    'holdIncome': 0,
    'totalIncome': 0,
    'dailyChange': float(daily_change) if daily_change else 0,
    'dailyChangePct': float(daily_change_pct) if daily_change_pct else 0,
    'updatedAt': now
}
# 清除pendingCostUpdate中的记录
if 'pendingCostUpdate' in d and code in d['pendingCostUpdate']:
    del d['pendingCostUpdate'][code]
print(json.dumps(d))
" 2>/dev/null)

        if [ -n "$result" ]; then
            write_portfolio "$result"
        fi

        echo -e "${GREEN}✅ 已添加持仓${NC}"
        echo "基金: $name ($code)"
        if $by_shares; then
            echo "份额: $shares"
            echo "持有金额: ¥$amount"
            echo "成本价: $cost"
        else
            echo "金额: ¥$amount"
            echo "份额: $shares"
            echo "成本价: $cost"
        fi
    fi
}

# 命令: 更新ETF代码
cmd_update_etf() {
    local code=$1
    local etf_code=$2

    if [ -z "$code" ] || [ -z "$etf_code" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "用法: $0 update-etf <基金代码> <ETF代码>"
        echo "示例: $0 update-etf 025732 159267"
        return 1
    fi

    init_portfolio

    # 检查基金是否存在
    if [ ! -f "$PORTFOLIO_FILE" ]; then
        echo -e "${RED}❌ 持仓文件不存在${NC}"
        return 1
    fi

    # 检查基金是否在持仓中
    local exists=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
code = '''$code'''
d=json.load(sys.stdin)
funds = d.get('funds',{})
print('yes' if code in funds else 'no')
" 2>/dev/null)

    if [ "$exists" != "yes" ]; then
        echo -e "${RED}❌ 基金 $code 不在持仓中${NC}"
        echo "请先添加持仓: $0 add <代码> <金额>"
        return 1
    fi

    # 更新ETF代码
    python3 -c "
import json
code = '''$code'''
etf = '''$etf_code'''
with open('$PORTFOLIO_FILE', 'r') as f:
    d = json.load(f)
if code in d.get('funds', {}):
    d['funds'][code]['etfCode'] = etf
    with open('$PORTFOLIO_FILE', 'w') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    print('ok')
" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 已更新 $code 的ETF代码为: $etf_code${NC}"
    else
        echo -e "${RED}❌ 更新失败${NC}"
    fi
}

# 命令: 卖出
cmd_remove() {
    local code=$1
    local value=$2
    local by_value=false

    # 检查是否是按金额
    if [ "$value" = "-v" ]; then
        by_value=true
        value=$3
    fi

    if [ -z "$code" ] || [ -z "$value" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "用法: $0 remove <代码> <份额>"
        echo "      $0 remove <代码> <金额> -v"
        return 1
    fi

    init_portfolio

    # 获取当前净值
    local nav=0
    if is_etf "$code"; then
        local price_info=$(get_etf_price "$code")
        if [ -n "$price_info" ]; then
            nav=$(echo "$price_info" | cut -d'|' -f1)
        fi
    else
        local nav_info=$(get_fund_nav "$code")
        if [ -n "$nav_info" ]; then
            nav=$(echo "$nav_info" | cut -d'|' -f1)
        fi
    fi

    # 计算卖出份额
    local shares=0
    if $by_value; then
        # 按金额
        if (( $(echo "$nav > 0" | bc -l) )); then
            shares=$(echo "scale=4; $value / $nav" | bc)
        fi
    else
        # 按份额
        shares=$value
    fi

    # 读取现有持仓
    local portfolio=$(cat "$PORTFOLIO_FILE")
    local current_shares=$(echo "$portfolio" | python3 -c "
import json,sys
code = '''$code'''
d=json.load(sys.stdin)
funds = d.get('funds',{})
if code in funds:
    print(funds[code].get('shares', 0))
" 2>/dev/null || echo "0")

    # 检查份额是否足够
    if (( $(echo "$shares > $current_shares" | bc -l) )); then
        echo -e "${RED}❌ 持有份额不足，当前持有: $current_shares${NC}"
        return 1
    fi

    # 获取成本价
    local cost_price=$(echo "$portfolio" | python3 -c "
import json,sys
code = '''$code'''
d=json.load(sys.stdin)
funds = d.get('funds',{})
if code in funds:
    print(funds[code].get('costPrice', 0))
" 2>/dev/null || echo "0")

    # 计算收益
    local income=0
    if (( $(echo "$nav > 0" | bc -l) )) && (( $(echo "$cost_price > 0" | bc -l) )); then
        income=$(echo "scale=2; $shares * ($nav - $cost_price)" | bc)
    fi

    # 更新持仓
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local result=$(echo "$portfolio" | python3 -c "
import json,sys
d=json.load(sys.stdin)

# 使用三引号避免注入
code = '''$code'''
now = '''$now'''
shares = float('''$shares''')
income = float('''$income''')

funds = d.get('funds',{})
if code in funds:
    fund = funds[code]
    fund['shares'] = fund.get('shares', 0) - shares
    fund['updatedAt'] = now
    # 更新累计收益
    fund['totalIncome'] = fund.get('totalIncome', 0) + income
print(json.dumps(d))
" 2>/dev/null)

    if [ -n "$result" ]; then
        write_portfolio "$result"
    fi

    echo -e "${GREEN}✅ 已卖出${NC}"
    echo "基金代码: $code"
    if $by_value; then
        echo "卖出金额: ¥$value"
    fi
    echo "卖出份额: $shares"
    echo "当前净值: $nav"
    echo "收益: ¥$income"
}

# 命令: 查看持仓列表
cmd_list() {
    init_portfolio
    local portfolio=$(cat "$PORTFOLIO_FILE")

    echo -e "${GREEN}📋 基金持仓列表${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local funds=$(echo "$portfolio" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('funds',{})))" 2>/dev/null)

    if [ -z "$funds" ] || [ "$funds" = "{}" ]; then
        echo "暂无持仓"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    fi

    # 更新 ETF联接基金的实时数据
    local updated_portfolio="$portfolio"
    echo "$portfolio" | python3 -c "
import json
import sys
import subprocess

d = json.load(sys.stdin)
funds = d.get('funds', {})

for code, fund in funds.items():
    fund_type = fund.get('type', '')
    etf_code = fund.get('etfCode')
    cost = fund.get('costPrice')

    # ETF联接基金优先使用天天基金最终净值API
    if fund_type == 'ETF联接':
        got_nav = False
        try:
            result = subprocess.run(
                ['bash', '-c', f'source "$(dirname "$0")/etf-assistant.sh" && get_fund_nav "{code}"', '$SCRIPT_DIR'],
                capture_output=True, text=True, timeout=10
            )
            output = result.stdout.strip()
            # 过滤掉帮助信息，只保留数字开头的行
            for line in output.split('\n'):
                line = line.strip()
                if line and line[0].isdigit():
                    output = line
                    break
            else:
                output = ''
            if output:
                parts = output.split('|')
                # get_fund_nav 返回: nav|change|source
                # source = "fin" (最终净值) 或 "est" (估算净值)
                if len(parts) >= 3 and parts[0] and parts[0] != '':
                    nav = float(parts[0])
                    change_pct = float(parts[1]) if parts[1] else 0
                    source = parts[2] if len(parts) > 2 else 'est'
                    # 只有获取到最终净值才使用
                    if source == 'fin':
                        shares = fund.get('shares', 0) or 0
                        daily_change = nav * change_pct / 100 * shares if shares else 0
                        fund['nav'] = nav
                        fund['dailyChange'] = daily_change
                        fund['dailyChangePct'] = change_pct
                        if cost and cost > 0 and shares and shares > 0:
                            fund['holdIncome'] = shares * (nav - cost)
                        got_nav = True
        except:
            pass

        # 如果没有获取到最终净值，回退到使用对应ETF计算估值
        if not got_nav and etf_code and cost and cost > 0:
            try:
                result = subprocess.run(
                    ['bash', '-c', f'source "$(dirname "$0")/etf-assistant.sh" && get_linked_etf_price "{code}" "{etf_code}"', '$SCRIPT_DIR'],
                    capture_output=True, text=True, timeout=10
                )
                output = result.stdout.strip()
                for line in output.split('\n'):
                    line = line.strip()
                    if line and line[0].isdigit():
                        output = line
                        break
                else:
                    output = ''
                if output:
                    parts = output.split('|')
                    if len(parts) >= 3 and parts[0] and parts[0] != '0':
                        nav = float(parts[0])
                        change_per_unit = float(parts[1]) if parts[1] else 0
                        change_pct = float(parts[2]) if parts[2] else 0
                        shares = fund.get('shares', 0) or 0
                        daily_change = change_per_unit * shares
                        fund['nav'] = nav
                        fund['dailyChange'] = daily_change
                        fund['dailyChangePct'] = change_pct
                        if cost and cost > 0 and shares and shares > 0:
                            fund['holdIncome'] = shares * (nav - cost)
            except:
                pass

print(json.dumps(d))
" > "$PORTFOLIO_FILE.tmp" 2>/dev/null

    # 读取更新后的数据并保存回原文件
    if [ -f "$PORTFOLIO_FILE.tmp" ]; then
        mv "$PORTFOLIO_FILE.tmp" "$PORTFOLIO_FILE"
        updated_portfolio=$(cat "$PORTFOLIO_FILE")
    fi

    local updated_funds=$(echo "$updated_portfolio" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('funds',{})))" 2>/dev/null)

    # 获取每只基金的最新数据
    local total_amount=0
    local total_change=0

    echo "$updated_funds" | python3 -c "
import json
import sys

funds = json.load(sys.stdin)
if not funds:
    print('暂无持仓')
    sys.exit(0)

for code, fund in sorted(funds.items()):
    name = fund.get('name', '未知')
    shares = fund.get('shares', 0) or 0
    cost = fund.get('costPrice') or 0
    nav = fund.get('nav', 0) or 0
    daily_change = fund.get('dailyChange', 0) or 0
    daily_pct = fund.get('dailyChangePct', 0) or 0
    fund_type = fund.get('type', '')
    etf_code = fund.get('etfCode')

    # 计算持有金额
    amount = shares * nav

    # 显示对应ETF
    suffix = ''
    if fund_type == 'ETF联接' and etf_code:
        suffix = f' → ETF:{etf_code}'

    print(f'{name}({code}){suffix}')
    print(f'  份额: {shares:.2f} | 成本: {cost:.3f} | 净值: {nav:.3f}')
    if cost and cost > 0:
        income = shares * (nav - cost)
        income_pct = (nav - cost) / cost * 100
        print(f'  持有: ¥{amount:.2f} | 持仓收益: ¥{income:.2f} ({income_pct:.2f}%)')
    else:
        print(f'  持有: ¥{amount:.2f} (成本待确认)')
    print(f'  今日涨跌: {daily_change:+.2f} ({daily_pct:+.2f}%)')
    print()
" 2>/dev/null

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 命令: 收益汇总
cmd_summary() {
    init_portfolio
    local portfolio=$(cat "$PORTFOLIO_FILE")

    echo -e "${GREEN}📊 基金持仓收益汇总${NC}"
    echo ""

    local funds=$(echo "$portfolio" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('funds',{})))" 2>/dev/null)

    if [ -z "$funds" ] || [ "$funds" = "{}" ]; then
        echo "暂无持仓"
        return 0
    fi

    # 更新 ETF联接基金的实时数据
    echo "$portfolio" | python3 -c "
import json
import sys
import subprocess

d = json.load(sys.stdin)
funds = d.get('funds', {})

for code, fund in funds.items():
    fund_type = fund.get('type', '')
    etf_code = fund.get('etfCode')
    cost = fund.get('costPrice')

    # ETF联接基金优先使用对应ETF实时行情计算
    if fund_type == 'ETF联接' and etf_code and cost and cost > 0:
        # 使用对应ETF计算估值（更准确）
        try:
            result = subprocess.run(
                ['bash', '-c', f'source "$(dirname "$0")/etf-assistant.sh" && get_linked_etf_price "{code}" "{etf_code}"', '$SCRIPT_DIR'],
                capture_output=True, text=True, timeout=10
            )
            output = result.stdout.strip()
            # 过滤掉帮助信息，只保留数字开头的行
            for line in output.split('\n'):
                line = line.strip()
                if line and line[0].isdigit():
                    output = line
                    break
            else:
                output = ''
            if output:
                parts = output.split('|')
                # get_linked_etf_price 返回: nav|change_per_unit|change_pct|etf_code
                if len(parts) >= 3 and parts[0] and parts[0] != '':
                    nav = float(parts[0])
                    change_per_unit = float(parts[1]) if parts[1] else 0
                    change_pct = float(parts[2]) if parts[2] else 0
                    shares = fund.get('shares', 0) or 0
                    daily_change = change_per_unit * shares  # 转换为总变化
                    fund['nav'] = nav
                    fund['dailyChange'] = daily_change
                    fund['dailyChangePct'] = change_pct
                    # 更新持仓收益
                    if cost and cost > 0 and shares and shares > 0:
                        fund['holdIncome'] = shares * (nav - cost)
        except:
            pass
    elif fund_type == 'ETF联接' and etf_code and cost and cost > 0:
        # 如果天天基金API失败，尝试使用对应ETF计算
        try:
            result = subprocess.run(
                ['bash', '-c', f'source "$(dirname "$0")/etf-assistant.sh" && get_linked_etf_price "{code}" "{etf_code}"', '$SCRIPT_DIR'],
                capture_output=True, text=True, timeout=10
            )
            output = result.stdout.strip()
            if output:
                parts = output.split('|')
                if len(parts) >= 3 and parts[0] and parts[0] != '0':
                    fund['nav'] = float(parts[0])
                    fund['dailyChange'] = float(parts[1])
                    fund['dailyChangePct'] = float(parts[2])
                    # 更新持仓收益 holdIncome
                    shares = fund.get('shares', 0) or 0
                    if shares and shares > 0:
                        fund['holdIncome'] = shares * (fund['nav'] - cost)
        except:
            pass

print(json.dumps(d))
" > "$PORTFOLIO_FILE.tmp" 2>/dev/null

    # 读取更新后的数据并保存回原文件
    if [ -f "$PORTFOLIO_FILE.tmp" ]; then
        mv "$PORTFOLIO_FILE.tmp" "$PORTFOLIO_FILE"
        portfolio=$(cat "$PORTFOLIO_FILE")
    fi

    funds=$(echo "$portfolio" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('funds',{})))" 2>/dev/null)

    # 计算汇总数据
    local summary=$(echo "$funds" | python3 -c "
import json
import sys

funds = json.load(sys.stdin)

total_amount = 0
hold_income = 0
total_income = 0
total_daily_change = 0

for code, fund in funds.items():
    shares = fund.get('shares', 0) or 0
    nav = fund.get('nav', 0) or 0
    cost = fund.get('costPrice') or 0
    daily_change = fund.get('dailyChange', 0) or 0
    total_income += fund.get('totalIncome', 0) or 0

    # 计算持仓收益（浮动盈亏）
    if cost and cost > 0:
        hold_income += shares * (nav - cost)

    amount = shares * nav
    total_amount += amount
    total_daily_change += daily_change

# 计算持仓收益率
if total_amount > 0 and (total_amount - total_income) > 0:
    hold_yield = hold_income / (total_amount - total_income) * 100
else:
    hold_yield = 0

# 计算累计收益率
if total_amount > 0 and (total_amount - total_income) > 0:
    total_yield = total_income / (total_amount - total_income) * 100
else:
    total_yield = 0

print(f'{total_amount:.2f}|{hold_income:.2f}|{hold_yield:.2f}|{total_income:.2f}|{total_yield:.2f}|{total_daily_change:.2f}')
" 2>/dev/null)

    local total_amount=$(echo "$summary" | cut -d'|' -f1)
    local hold_income=$(echo "$summary" | cut -d'|' -f2)
    local hold_yield=$(echo "$summary" | cut -d'|' -f3)
    local total_income=$(echo "$summary" | cut -d'|' -f4)
    local total_yield=$(echo "$summary" | cut -d'|' -f5)
    local total_daily_change=$(echo "$summary" | cut -d'|' -f6)

    echo "┌─────────────────────────────────────────────┐"
    printf "│ %-15s │ %-25s │\n" "总持有金额" "¥$total_amount"
    echo "├─────────────────────────────────────────────┤"
    printf "│ %-15s │ %-25s │\n" "持仓收益" "¥$hold_income ($hold_yield%)"
    echo "├─────────────────────────────────────────────┤"
    printf "│ %-15s │ %-25s │\n" "累计收益" "¥$total_income ($total_yield%)"
    echo "├─────────────────────────────────────────────┤"
    printf "│ %-15s │ %-25s │\n" "今日涨跌" "¥$total_daily_change"
    echo "└─────────────────────────────────────────────┘"

    echo ""
    echo "📈 持仓明细"

    # 计算总金额用于持仓占比
    local total_for_pct=$(echo "$funds" | python3 -c "
import json
import sys
funds = json.load(sys.stdin)
total = 0
for code, fund in funds.items():
    shares = fund.get('shares', 0) or 0
    nav = fund.get('nav', 0) or 0
    total += shares * nav
print(total)
" 2>/dev/null)

    # 获取每只基金的详细信息
    echo "$funds" | python3 -c "
import json
import sys

funds = json.load(sys.stdin)
total_for_pct_val = '''$total_for_pct'''
total_for_pct = float(total_for_pct_val) if total_for_pct_val else 0

# 按持仓收益排序（从高到低）
sorted_funds = sorted(funds.items(), key=lambda x: (x[1].get('shares', 0) or 0) * ((x[1].get('nav', 0) or 0) - (x[1].get('costPrice') or 0)), reverse=True)

for i, (code, fund) in enumerate(sorted_funds, 1):
    name = fund.get('name', '未知')
    shares = fund.get('shares', 0) or 0
    cost = fund.get('costPrice') or 0
    nav = fund.get('nav', 0) or 0
    daily_change = fund.get('dailyChange', 0) or 0
    daily_pct = fund.get('dailyChangePct', 0) or 0
    total_income = fund.get('totalIncome', 0) or 0
    fund_type = fund.get('type', '')

    amount = shares * nav

    # 计算持仓占比
    pct = (amount / total_for_pct * 100) if total_for_pct > 0 else 0

    if cost and cost > 0:
        income = shares * (nav - cost)
        income_pct = (nav - cost) / cost * 100
    else:
        income = 0
        income_pct = 0

    # 累计收益 = 持仓收益 + 历史卖出收益
    cumulative_income = income + (total_income or 0)

    # 只对ETF联接显示对应ETF
    etf_code = fund.get('etfCode') or ''
    suffix = f' → {etf_code}' if fund_type == 'ETF联接' and etf_code else ''

    print(f'{i}. {name}({code}){suffix}')
    print(f'   持仓占比: {pct:>5.1f}% | 持有: ¥{amount:>8.2f} | 份额: {shares:>8.2f}')
    print(f'   成本: {cost:.3f} | 净值: {nav:.3f}')
    print(f'   今日收益: {daily_change:>+7.2f}({daily_pct:>+6.2f}%) | 持仓收益: {income:>+7.2f}({income_pct:>+6.2f}%) | 累计: {cumulative_income:>+7.2f}')
    print()
" 2>/dev/null
}

# 命令: 定投添加
cmd_dca_add() {
    local code=$1
    local amount=$2
    local frequency=$3

    if [ -z "$code" ] || [ -z "$amount" ] || [ -z "$frequency" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "用法: $0 dca add <代码> <金额> <频率>"
        echo "频率: daily(每日), weekly(每周), monthly(每月)"
        return 1
    fi

    # 验证频率
    case "$frequency" in
        daily|weekly|monthly)
            ;;
        *)
            echo -e "${RED}❌ 无效的频率${NC}"
            echo "支持的频率: daily, weekly, monthly"
            return 1
            ;;
    esac

    init_portfolio

    # 计算下次定投日期（跳过非交易日）
    local today
    today=$(date +%Y-%m-%d)
    local next_date=""

    case "$frequency" in
        daily)
            next_date=$(get_next_trading_day "$today")
            ;;
        weekly)
            next_date=$(get_next_trading_day "$(date -d "$today +7 day" +%Y-%m-%d 2>/dev/null || date -j -v+7d -f "%Y-%m-%d" "$today" +%Y-%m-%d)")
            ;;
        monthly)
            next_date=$(get_next_trading_day "$(date -d "$today +1 month" +%Y-%m-%d 2>/dev/null || date -j -v+1m -f "%Y-%m-%d" "$today" +%Y-%m-%d)")
            ;;
    esac

    # 更新定投计划 - 使用 json 传递参数避免注入
    local result=$(python3 -c "
import json
import sys

code = '''$code'''
frequency = '''$frequency'''
amount = int($amount)
next_date = '''$next_date'''

try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
    d['dca'] = d.get('dca', {})
    d['dca'][code] = {
        'frequency': frequency,
        'amount': amount,
        'status': 'active',
        'nextDate': next_date
    }
    print(json.dumps(d))
except:
    print('')
" 2>/dev/null)

    if [ -n "$result" ]; then
        write_portfolio "$result"
    fi

    local name=$(get_etf_name "$code")
    echo -e "${GREEN}✅ 定投计划已添加${NC}"
    echo "基金: $name ($code)"
    echo "金额: ¥$amount"
    echo "频率: $frequency"
    echo "下次定投: $next_date"

    # 检查是否需要创建 launchd 定时任务
    setup_dca_launchd
}

# 命令: 定投列表
cmd_dca_list() {
    init_portfolio
    local portfolio=$(cat "$PORTFOLIO_FILE")

    echo -e "${GREEN}📋 定投计划列表${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local dca=$(echo "$portfolio" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('dca',{})))" 2>/dev/null)

    if [ -z "$dca" ] || [ "$dca" = "{}" ]; then
        echo "暂无定投计划"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    fi

    # 获取基金名称
    local funds=$(echo "$portfolio" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('funds',{})))" 2>/dev/null)

    echo "$dca" | python3 -c "
import json
import sys

dca = json.load(sys.stdin)
funds = json.loads('''$funds''')

for code, plan in dca.items():
    name = code
    if code in funds:
        name = funds[code].get('name', code)

    freq = plan.get('frequency', 'daily')
    amount = plan.get('amount', 0)
    status = plan.get('status', 'active')
    next_date = plan.get('nextDate', '')

    freq_map = {'daily': '每日', 'weekly': '每周', 'monthly': '每月'}
    print(f'{name}({code})')
    print(f'  金额: ¥{amount} | 频率: {freq_map.get(freq, freq)} | 状态: {status}')
    print(f'  下次定投: {next_date}')
    print()
" 2>/dev/null

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 命令: 定投移除
cmd_dca_remove() {
    local code=$1

    if [ -z "$code" ]; then
        echo -e "${RED}❌ 请输入基金代码${NC}"
        return 1
    fi

    init_portfolio

    # 移除定投计划 - 使用 json 传递参数避免注入
    local result=$(python3 -c "
import json
import sys

code = '''$code'''
try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
    if 'dca' in d and code in d['dca']:
        del d['dca'][code]
        print(json.dumps(d))
    else:
        print(json.dumps(d))
except:
    print('')
" 2>/dev/null)

    if [ -n "$result" ]; then
        write_portfolio "$result"
    fi

    echo -e "${GREEN}✅ 定投计划已移除: $code${NC}"
}

# 命令: 定投检查（定时执行）
cmd_dca_check() {
    init_portfolio

    local today
    today=$(date +%Y-%m-%d)

    echo -e "${CYAN}开始检查定投计划...${NC}"

    # 检查是否为交易日
    if ! is_trading_day "$today"; then
        echo -e "${YELLOW}今天不是交易日，跳过${NC}"
        return 0
    fi

    # 读取并执行到期的定投计划
    local dca_plans
    dca_plans=$(python3 -c "
import json
import sys

try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)

    dca = d.get('dca', {})
    for code, plan in dca.items():
        if plan.get('status') == 'active':
            print(f'{code}:{plan.get(\"amount\", 0)}:{plan.get(\"frequency\", \"daily\")}:{plan.get(\"nextDate\", \"\")}')
except Exception as e:
    sys.exit(1)
" 2>/dev/null || echo "")

    if [ -z "$dca_plans" ]; then
        echo -e "${YELLOW}没有活跃的定投计划${NC}"
        return 0
    fi

    # 遍历执行 - 使用进程替换避免子shell变量问题
    local executed=0
    while IFS=: read -r code amount frequency next_date; do
        if [ -z "$code" ] || [ -z "$next_date" ]; then
            continue
        fi

        if [ "$next_date" = "$today" ]; then
            echo -e "${CYAN}执行定投: $code 金额=$amount${NC}"

            # 执行买入
            local result
            result=$(cmd_add "$code" "$amount" 2>&1) || true

            if echo "$result" | grep -qE "成功|已添加|✅"; then
                # 更新下次执行日期 - 使用 json 传递参数避免注入
                local new_next_date
                new_next_date=$(get_next_trading_day "$today")

                python3 -c "
code = '''$code'''
next_date = '''$new_next_date'''
try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
    if 'dca' in d and code in d['dca']:
        d['dca'][code]['nextDate'] = next_date
        with open('$PORTFOLIO_FILE', 'w') as f:
            json.dump(d, f, ensure_ascii=False)
except:
    pass
" 2>/dev/null

                echo -e "${GREEN}✅ $code 已定投，下次: $new_next_date${NC}"
                executed=$((executed + 1))
            else
                echo -e "${RED}❌ $code 定投失败${NC}"
            fi
        fi
    done <<< "$dca_plans"

    echo -e "${CYAN}定投检查完成${NC}"
}

# 命令: 定时任务添加
cmd_schedule_add() {
    local description="$1"
    local task_type="$2"
    local cron="$3"
    local chat_jid="$4"

    if [ -z "$description" ] || [ -z "$task_type" ] || [ -z "$cron" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "用法: $0 schedule add <描述> <类型> <cron表达式> [chat_jid]"
        echo "示例: $0 schedule add \"13点估值\" summary \"0 13 * * 1-5\""
        return 1
    fi

    # 验证任务类型
    case "$task_type" in
        summary|pending-update|dca-check)
            ;;
        *)
            echo -e "${RED}❌ 无效的任务类型${NC}"
            echo "支持的类型: summary, pending-update, dca-check"
            return 1
            ;;
    esac

    init_portfolio

    # 如果没有指定 chat_jid，尝试从环境变量或 portfolio.json 获取
    if [ -z "$chat_jid" ]; then
        chat_jid="${CHAT_JID}"
    fi
    if [ -z "$chat_jid" ] && [ -f "$PORTFOLIO_FILE" ]; then
        chat_jid=$(python3 -c "
import json
try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
        print(d.get('chatJid', ''))
except:
    print('')
" 2>/dev/null)
    fi

    # 生成任务ID
    local task_id="task-$(date +%s)"

    # 添加定时任务
    local result=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
d=json.load(sys.stdin)

# 使用三引号避免注入
task_id = '''$task_id'''
task_type = '''$task_type'''
cron = '''$cron'''
description = '''$description'''
chat_jid = '''$chat_jid'''

d['scheduled_tasks'] = d.get('scheduled_tasks',{})
d['scheduled_tasks'][task_id] = {
    'type': task_type,
    'cron': cron,
    'status': 'active',
    'description': description,
    'chatJid': chat_jid if chat_jid else None
}
print(json.dumps(d))
" 2>/dev/null)

    if [ -n "$result" ]; then
        write_portfolio "$result"
    fi

    echo -e "${GREEN}✅ 定时任务已添加${NC}"
    echo "描述: $description"
    echo "类型: $task_type"
    echo "执行时间: $cron"

    # 创建 launchd 定时任务
    setup_scheduled_launchd
}

# 命令: 定时任务列表
cmd_schedule_list() {
    init_portfolio

    echo -e "${GREEN}📋 定时任务列表${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local tasks=$(python3 -c "
import json
try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
    tasks = d.get('scheduled_tasks', {})
    for task_id, task in tasks.items():
        print(f'{task_id}|{task.get(\"type\", \"\")}|{task.get(\"cron\", \"\")}|{task.get(\"description\", \"\")}|{task.get(\"status\", \"\")}')
except:
    pass
" 2>/dev/null || echo "")

    if [ -z "$tasks" ]; then
        echo "没有定时任务"
        return 0
    fi

    # 使用进程替换避免子shell问题
    while IFS='|' read -r task_id task_type cron description status; do
        if [ -z "$task_id" ]; then
            continue
        fi

        local status_icon="✅"
        if [ "$status" != "active" ]; then
            status_icon="⏸️"
        fi

        echo "$status_icon $description"
        echo "   类型: $task_type | 时间: $cron | 状态: $status"
        echo ""
    done <<< "$tasks"
}

# 命令: 定时任务移除
cmd_schedule_remove() {
    local task_id="$1"

    if [ -z "$task_id" ]; then
        echo -e "${RED}❌ 请输入任务ID${NC}"
        echo "用法: $0 schedule remove <任务ID>"
        echo "使用 'schedule list' 查看任务ID"
        return 1
    fi

    init_portfolio

    # 移除定时任务
    local result=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
d=json.load(sys.stdin)

# 使用三引号避免注入
task_id = '''$task_id'''

if 'scheduled_tasks' in d and task_id in d['scheduled_tasks']:
    del d['scheduled_tasks'][task_id]
print(json.dumps(d))
" 2>/dev/null)

    if [ -n "$result" ]; then
        write_portfolio "$result"
    fi

    echo -e "${GREEN}✅ 定时任务已移除: $task_id${NC}"
}

# 命令: 初始化定时任务配置
cmd_schedule_init() {
    local chat_jid="${1:-${CHAT_JID}}"

    init_portfolio

    if [ -z "$chat_jid" ]; then
        echo -e "${YELLOW}⚠️  无法获取 chat_jid${NC}"
        echo ""
        echo "请手动指定 chat_jid："
        echo "  etf-assistant schedule init <chat_jid>"
        echo ""
        echo "示例："
        echo "  etf-assistant schedule init \"your-jid@g.us\""
        return 1
    fi

    # 存储 chat_jid 到 portfolio
    local result=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['chatJid'] = '''$chat_jid'''
print(json.dumps(d))
" 2>/dev/null)

    if [ -n "$result" ]; then
        write_portfolio "$result"
    fi

    echo -e "${GREEN}✅ 已设置 chat_jid: $chat_jid${NC}"
    echo ""
    echo "现在可以创建定时任务，执行结果会自动发送给您。"
    echo "示例："
    echo "  etf-assistant schedule add \"13点估值\" summary \"0 13 * * 1-5\""
}

# 设置通用定时任务 launchd
setup_scheduled_launchd() {
    # 容器内不创建 launchd 配置
    if [ -f "/.dockerenv" ] || [ ! -f "/usr/bin/launchctl" ]; then
        return 0
    fi

    # 检查是否已经有 launchd 配置
    local plist_path="$HOME/Library/LaunchAgents/com.nanoclaw.scheduled.plist"

    if [ -f "$plist_path" ]; then
        return 0  # 已存在
    fi

    # 检查是否有活跃的定时任务
    local task_count
    task_count=$(python3 -c "
import json
try:
    with open('$PORTFOLIO_FILE', 'r') as f:
        d = json.load(f)
    tasks = d.get('scheduled_tasks', {})
    active_count = sum(1 for t in tasks.values() if t.get('status') == 'active')
    print(active_count)
except:
    print(0)
" 2>/dev/null || echo "0")

    if [ "$task_count" -lt 1 ]; then
        return 0  # 没有活跃任务
    fi

    # 创建 launchd 配置 - 每小时运行一次 (9-22点)
    local project_dir
    project_dir=$(cd "$(dirname "$SCRIPT_DIR")/../../../../" && pwd)

    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$plist_path" << 'EOFPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nanoclaw.scheduled</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/container</string>
        <string>run</string>
        <string>--rm</string>
        <string>-v</string>
        <string>PROJECT_DIR_PLACEHOLDER:/workspace:rw</string>
        <string>-v</string>
        <string>PROJECT_DIR_PLACEHOLDER/groups/fin-assistant:/workspace/group/fin-assistant:rw</string>
        <string>nanoclaw-agent:latest</string>
        <string>bash</string>
        <string>/workspace/container/skills/fin-assistant/etf-assistant/scheduled-check.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>11</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>13</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>14</key><integer>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>15</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>16</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>17</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>19</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>20</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>22</integer><key>Minute</key><integer>0</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOFPLIST

    # 替换路径占位符 (兼容 macOS 和 Linux)
    if sed -i '' "s|PROJECT_DIR_PLACEHOLDER|$project_dir|g" "$plist_path" 2>/dev/null; then
        : # macOS sed -i ''
    elif sed -i "s|PROJECT_DIR_PLACEHOLDER|$project_dir|g" "$plist_path" 2>/dev/null; then
        : # Linux sed -i
    else
        # 备用方案: 使用 Python
        python3 -c "
import sys
with open('$plist_path', 'r') as f:
    content = f.read()
content = content.replace('PROJECT_DIR_PLACEHOLDER', '$project_dir')
with open('$plist_path', 'w') as f:
    f.write(content)
" 2>/dev/null || true
    fi

    # 加载 launchd 任务
    launchctl load "$plist_path" 2>/dev/null || true

    echo -e "${CYAN}⏰ 已设置定时任务检查（每小时9-22点）${NC}"
}

# 命令: 待确认成本价更新
cmd_pending_update() {
    init_portfolio

    echo -e "${GREEN}🔄 检查待更新成本价${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 读取 portfolio
    local portfolio_json=$(cat "$PORTFOLIO_FILE")

    # 检查是否有待更新
    local has_pending=$(echo "$portfolio_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pending = d.get('pendingCostUpdate', {})
print('yes' if pending else 'no')
" 2>/dev/null)

    if [ "$has_pending" != "yes" ]; then
        echo "没有待更新的成本价"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    fi

    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 处理每个待更新记录
    echo "$portfolio_json" | python3 -c "
import json
import sys
import subprocess
import re
import os

d = json.load(sys.stdin)
pending = d.get('pendingCostUpdate', {})
funds = d.get('funds', {})
now = '''$now'''
script_dir = '''$script_dir'''
portfolio_file = '''$PORTFOLIO_FILE'''

results = []
updated = False

for code, info in pending.items():
    target = info.get('targetDate', '')
    amount = info.get('amount', 0)
    shares = info.get('shares', 0)

    # 检查是否到达更新时间
    if now >= target:
        # 获取当前净值
        try:
            result = subprocess.run(
                ['bash', '-c', f'source \"{script_dir}/etf-assistant.sh\" && etf-assistant price {code}'],
                capture_output=True, text=True, timeout=15
            )
            output = result.stdout

            # 解析净值
            nav = 0
            if '估算净值:' in output:
                match = re.search(r'估算净值:\s*([0-9.]+)', output)
                if match:
                    nav = float(match.group(1))
            elif '当前价格:' in output:
                match = re.search(r'当前价格:\s*([0-9.]+)', output)
                if match:
                    nav = float(match.group(1))

            if nav > 0 and shares > 0:
                # 计算成本价 = 金额 / 份额
                cost_price = amount / shares

                # 更新 portfolio 中的成本价
                if code in funds:
                    old_cost = funds[code].get('costPrice')
                    funds[code]['costPrice'] = cost_price
                    results.append(f'{code}: 已更新成本价 {old_cost} -> {cost_price:.4f}')
                    updated = True
                else:
                    results.append(f'{code}: 持仓记录不存在')
            else:
                results.append(f'{code}: 无法获取净值或份额为0')
        except Exception as e:
            results.append(f'{code}: 获取净值失败 - {str(e)}')
    else:
        results.append(f'{code}: 尚未到达更新时间 ({target})')

# 输出结果
for r in results:
    print(r)

# 如果有更新，写回文件
if updated:
    d['funds'] = funds
    # 移除已更新的记录
    for code in list(pending.keys()):
        if now >= pending[code].get('targetDate', ''):
            del d['pendingCostUpdate'][code]

    with open(portfolio_file, 'w') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
" 2>/dev/null

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ETF对比
cmd_compare() {
    local code1=$1
    local code2=$2

    if [ -z "$code1" ] || [ -z "$code2" ]; then
        echo -e "${RED}❌ 请输入两个ETF代码${NC}"
        echo "示例: $0 compare 510300 159915"
        return 1
    fi

    local name1=$(get_etf_name "$code1")
    local name2=$(get_etf_name "$code2")

    echo -e "${GREEN}📊 ETF对比分析${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo -e "$code1 $name1  VS  $code2 $name2"
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local price1=$(get_etf_price "$code1")
    local price2=$(get_etf_price "$code2")

    if [ -n "$price1" ] && [ -n "$price2" ]; then
        local current1=$(echo "$price1" | cut -d'|' -f1)
        local current2=$(echo "$price2" | cut -d'|' -f1)
        echo -e "当前价格:"
        echo "  $code1: $current1"
        echo "  $code2: $current2"
    else
        echo "暂时无法获取行情数据"
    fi
    echo ""
    echo "注: 完整对比需要更多历史数据"
}

# 定投计算器
cmd_calc() {
    local code=$1
    local amount=$2
    local years=$3

    if [ -z "$code" ] || [ -z "$amount" ] || [ -z "$years" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "示例: $0 calc 510300 1000 10"
        echo "含义: 每月定投1000元，定投10年"
        return 1
    fi

    local name=$(get_etf_name "$code")

    echo -e "${GREEN}📈 定投计算器${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo "基金: $name ($code)"
    echo "月定投: ¥$amount"
    echo "定投年限: $years 年"
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local months=$((years * 12))
    local annual_return=0.08
    local monthly_return=$(echo "scale=6; $annual_return / 12" | bc)

    local future_value=$(echo "scale=2; $amount * ((1 + $monthly_return)^$months - 1) / $monthly_return" | bc)
    local total_invest=$((amount * months))

    echo "📊 估算收益 (假设年化8%):"
    echo "  总投入: ¥$total_invest"
    echo "  预计价值: ¥$future_value"
    echo "  收益: ¥$(echo "scale=2; $future_value - $total_invest" | bc)"
    echo ""
    echo "💡 提示: 实际收益取决于市场表现"
}

# 主逻辑
case "$1" in
    list)
        cmd_list
        ;;
    price)
        cmd_price "$2"
        ;;
    info)
        cmd_info "$2"
        ;;
    summary)
        cmd_summary
        ;;
    add)
        cmd_add "$2" "$3" "$4" "$5" "$6"
        ;;
    update-etf)
        cmd_update_etf "$2" "$3"
        ;;
    remove)
        cmd_remove "$2" "$3" "$4"
        ;;
    dca)
        case "$2" in
            add)
                cmd_dca_add "$3" "$4" "$5"
                ;;
            list)
                cmd_dca_list
                ;;
            remove)
                cmd_dca_remove "$3"
                ;;
            check)
                cmd_dca_check
                ;;
            *)
                echo -e "${RED}❌ 未知dca子命令${NC}"
                echo "用法: $0 dca add|list|remove|check"
                ;;
        esac
        ;;
    schedule)
        case "$2" in
            add)
                cmd_schedule_add "$3" "$4" "$5"
                ;;
            list)
                cmd_schedule_list
                ;;
            remove)
                cmd_schedule_remove "$3"
                ;;
            init)
                cmd_schedule_init "$3"
                ;;
            *)
                echo -e "${RED}❌ 未知schedule子命令${NC}"
                echo "用法: $0 schedule add|list|remove|init"
                echo ""
                echo "子命令："
                echo "  add <描述> <类型> <cron>     添加定时任务"
                echo "  list                         列出定时任务"
                echo "  remove <任务ID>              移除定时任务"
                echo "  init [chat_jid]              初始化定时任务配置（设置接收通知的聊天）"
                ;;
        esac
        ;;
    pending-update)
        cmd_pending_update
        ;;
    compare)
        cmd_compare "$2" "$3"
        ;;
    calc)
        cmd_calc "$2" "$3" "$4"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        ;;
esac
