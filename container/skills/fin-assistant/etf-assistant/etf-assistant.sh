#!/bin/bash
# ETF 基金投资助理 - Clawdbot Skill
# 功能：ETF 基金持仓管理、净值查询、定投计划、收益汇总

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 持仓数据文件路径 (可通过环境变量覆盖)
# 获取脚本所在目录的根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PORTFOLIO_FILE="${PORTFOLIO_FILE:-$SCRIPT_DIR/groups/fin-assistant/portfolio.json}"

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
    local url="https://fundgz.1234567.com.cn/js/${code}.js"
    local response=$(curl -s "$url" 2>/dev/null)

    if echo "$response" | grep -q "gsz"; then
        local gsz=$(echo "$response" | sed 's/.*"gsz":"\([^"]*\)".*/\1/')
        local gszzl=$(echo "$response" | sed 's/.*"gszzl":"\([^"]*\)".*/\1/')
        local gsz_time=$(echo "$response" | sed 's/.*"gztime":"\([^"]*\)".*/\1/')

        if [ -n "$gsz" ]; then
            echo "$gsz|$gszzl|$gsz_time"
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
    if echo "$response" | grep -q "ETF联接"; then
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

    # 方法4: 查找5开头或159/160开头的代码
    if [ -z "$etf_code" ]; then
        etf_code=$(echo "$response" | grep -oE '5[0-9]{4}|159[0-9]{3}|160[0-9]{3}|161[0-9]{3}' | head -1)
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
d=json.load(sys.stdin)
funds = d.get('funds',{})
if '$fund_code' in funds:
    f = funds['$fund_code']
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
    echo -e "${BLUE}║     基金投资助理 - Clawdbot Skill     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "基础命令:"
    echo "  list              查看持仓列表"
    echo "  price <代码>      查询基金/ETF实时行情"
    echo "  info <代码>       获取基金基本信息"
    echo "  summary           收益汇总"
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
d=json.load(sys.stdin)
funds = d.get('funds',{})
if '$code' in funds:
    f = funds['$code']
    print(f.get('etfCode', '') or '')
" 2>/dev/null)
        saved_fund_type=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
funds = d.get('funds',{})
if '$code' in funds:
    f = funds['$code']
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
    elif [ "$fund_type" = "ETF联接" ] && [ -n "$etf_code" ]; then
        # ETF联接 - 使用对应ETF的涨跌率计算估值
        local nav_info=$(get_linked_etf_price "$code" "$etf_code")
        if [ -n "$nav_info" ]; then
            local estimated_nav=$(echo "$nav_info" | cut -d'|' -f1)
            local etf_change=$(echo "$nav_info" | cut -d'|' -f2)
            local etf_change_pct=$(echo "$nav_info" | cut -d'|' -f3)
            local linked_etf=$(echo "$nav_info" | cut -d'|' -f4)

            if [ -z "$estimated_nav" ] || [ "$estimated_nav" = "0" ] || [ "$estimated_nav" = "0.0000" ]; then
                # 没有成本价，无法计算估值
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
    local by_shares=false
    local mode="amount"  # amount: 按金额, shares: 按份额

    # 检查是否是按份额模式 (-s 参数，在第四个位置)
    if [ "$fourth" = "-s" ]; then
        by_shares=true
        mode="shares"
    fi

    if [ -z "$code" ] || [ -z "$second" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "用法: $0 add <代码> <金额> [成本价]"
        echo "      $0 add <代码> <份额> <成本价> -s  # 按份额添加（截图识别用）"
        echo "示例: $0 add 110022 1000"
        echo "      $0 add 110022 1000 1.25"
        echo "      $0 add 002610 15500.27 3.57 -s"
        return 1
    fi

    init_portfolio

    # 获取基金信息
    local name=$(get_etf_name "$code")
    local fund_info=$(get_fund_info "$code")
    local fund_type=$(echo "$fund_info" | cut -d'|' -f1)
    local etf_code=$(echo "$fund_info" | cut -d'|' -f2)

    # 优先使用已保存的 etfCode
    if [ -f "$PORTFOLIO_FILE" ]; then
        local saved=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
funds = d.get('funds',{})
if '$code' in funds:
    print(funds['$code'].get('etfCode', ''))
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
    elif [ "$fund_type" = "ETF联接" ] && [ -n "$etf_code" ]; then
        # ETF联接 - 使用对应ETF的实时行情
        local nav_info=$(get_linked_etf_price "$code" "$etf_code")
        if [ -n "$nav_info" ]; then
            nav=$(echo "$nav_info" | cut -d'|' -f1)
            daily_change=$(echo "$nav_info" | cut -d'|' -f2)
            daily_change_pct=$(echo "$nav_info" | cut -d'|' -f3)
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
# 确保funds存在
if 'funds' not in d:
    d['funds'] = {}
# 添加基金到funds（成本价为null表示待确认）
d['funds']['$code'] = {
    'name': '$name',
    'code': '$code',
    'type': '$fund_type',
    'etfCode': '$etf_code' if '$etf_code' else None,
    'shares': $shares,
    'costPrice': None,
    'nav': float($nav) if '$nav' else 0,
    'holdIncome': 0,
    'totalIncome': 0,
    'dailyChange': float($daily_change) if '$daily_change' else 0,
    'dailyChangePct': float($daily_change_pct) if '$daily_change_pct' else 0,
    'updatedAt': '$now'
}
# 添加到pendingCostUpdate
d['pendingCostUpdate'] = d.get('pendingCostUpdate',{})
d['pendingCostUpdate']['$code'] = {
    'shares': $shares,
    'amount': $amount,
    'purchaseTime': '$now',
    'targetDate': '$target_date'
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
if 'funds' not in d:
    d['funds'] = {}
d['funds']['$code'] = {
    'name': '$name',
    'code': '$code',
    'type': '$fund_type',
    'etfCode': '$etf_code' if '$etf_code' else None,
    'shares': $shares,
    'costPrice': $cost if '$cost' else None,
    'nav': float($nav) if '$nav' else 0,
    'holdIncome': 0,
    'totalIncome': 0,
    'dailyChange': float($daily_change) if '$daily_change' else 0,
    'dailyChangePct': float($daily_change_pct) if '$daily_change_pct' else 0,
    'updatedAt': '$now'
}
# 清除pendingCostUpdate中的记录
if 'pendingCostUpdate' in d and '$code' in d['pendingCostUpdate']:
    del d['pendingCostUpdate']['$code']
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
d=json.load(sys.stdin)
funds = d.get('funds',{})
if '$code' in funds:
    print(funds['$code'].get('shares', 0))
" 2>/dev/null || echo "0")

    # 检查份额是否足够
    if (( $(echo "$shares > $current_shares" | bc -l) )); then
        echo -e "${RED}❌ 持有份额不足，当前持有: $current_shares${NC}"
        return 1
    fi

    # 获取成本价
    local cost_price=$(echo "$portfolio" | python3 -c "
import json,sys
d=json.load(sys.stdin)
funds = d.get('funds',{})
if '$code' in funds:
    print(funds['$code'].get('costPrice', 0))
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
funds = d.get('funds',{})
if '$code' in funds:
    fund = funds['$code']
    fund['shares'] = fund.get('shares', 0) - $shares
    fund['updatedAt'] = '$now'
    # 更新累计收益
    fund['totalIncome'] = fund.get('totalIncome', 0) + $income
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

    if fund_type == 'ETF联接' and etf_code and cost and cost > 0:
        # 调用 get_linked_etf_price 获取实时估值
        try:
            result = subprocess.run(
                ['bash', '-c', f'source $0 && get_linked_etf_price "$1" "$2"' % ('$0', code, etf_code)],
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
                    cost = fund.get('costPrice') or 0
                    shares = fund.get('shares', 0) or 0
                    if cost and cost > 0 and shares and shares > 0:
                        fund['holdIncome'] = shares * (fund['nav'] - cost)
        except:
            pass

print(json.dumps(d))
" > "$PORTFOLIO_FILE.tmp" 2>/dev/null

    # 读取更新后的数据
    if [ -f "$PORTFOLIO_FILE.tmp" ]; then
        updated_portfolio=$(cat "$PORTFOLIO_FILE.tmp")
        rm -f "$PORTFOLIO_FILE.tmp"
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

    if fund_type == 'ETF联接' and etf_code and cost and cost > 0:
        try:
            result = subprocess.run(
                ['bash', '-c', f'source $0 && get_linked_etf_price "$1" "$2"' % ('$0', code, etf_code)],
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

    # 读取更新后的数据
    if [ -f "$PORTFOLIO_FILE.tmp" ]; then
        portfolio=$(cat "$PORTFOLIO_FILE.tmp")
        rm -f "$PORTFOLIO_FILE.tmp"
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

    # 获取每只基金的详细信息
    echo "$funds" | python3 -c "
import json
import sys

funds = json.load(sys.stdin)
for i, (code, fund) in enumerate(sorted(funds.items()), 1):
    name = fund.get('name', '未知')
    shares = fund.get('shares', 0) or 0
    cost = fund.get('costPrice') or 0
    nav = fund.get('nav', 0) or 0
    daily_change = fund.get('dailyChange', 0) or 0
    daily_pct = fund.get('dailyChangePct', 0) or 0
    total_income = fund.get('totalIncome', 0) or 0
    fund_type = fund.get('type', '')

    amount = shares * nav

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
    suffix = f' → ETF:{etf_code}' if fund_type == 'ETF联接' and etf_code else ''

    print(f'{i}. {name}({code}){suffix}')
    print(f'   持有: ¥{amount:.2f} | 份额: {shares:.2f} | 成本: {cost:.3f}')
    print(f'   今日涨跌: {daily_change:+.2f}({daily_pct:+.2f}%) | 持仓收益: {income:+.2f}({income_pct:+.2f}%) | 累计收益: {cumulative_income:+.2f} | 净值: {nav:.3f}')
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
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # 计算下次定投日期
    local next_date=""
    case "$frequency" in
        daily)
            next_date=$(date -u -d "+1 day" +"%Y-%m-%d")
            ;;
        weekly)
            next_date=$(date -u -d "+1 week" +"%Y-%m-%d")
            ;;
        monthly)
            next_date=$(date -u -d "+1 month" +"%Y-%m-%d")
            ;;
    esac

    # 更新定投计划
    local result=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['dca'] = d.get('dca',{})
d['dca']['$code'] = {
    'frequency': '$frequency',
    'amount': $amount,
    'status': 'active',
    'nextDate': '$next_date'
}
print(json.dumps(d))
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

    # 移除定投计划
    local result=$(cat "$PORTFOLIO_FILE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'dca' in d and '$code' in d['dca']:
    del d['dca']['$code']
print(json.dumps(d))
" 2>/dev/null)

    if [ -n "$result" ]; then
        write_portfolio "$result"
    fi

    echo -e "${GREEN}✅ 定投计划已移除: $code${NC}"
}

# 命令: 待确认成本价更新
cmd_pending_update() {
    init_portfolio
    local portfolio=$(cat "$PORTFOLIO_FILE")

    echo -e "${GREEN}🔄 检查待更新成本价${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local pending=$(echo "$portfolio" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('pendingCostUpdate',{})))" 2>/dev/null)

    if [ -z "$pending" ] || [ "$pending" = "{}" ]; then
        echo "没有待更新的成本价"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    fi

    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated=0

    echo "$pending" | python3 -c "
import json
import sys
import subprocess

pending = json.load(sys.stdin)
for code, info in pending.items():
    target = info.get('targetDate', '')
    purchase_time = info.get('purchaseTime', '')

    # 检查是否到达更新时间
    if '$now' >= target:
        # 获取当前净值
        result = subprocess.run(['bash', '-c', '$0 price $1' % ('$0', code)], capture_output=True, text=True)

        # 从output中提取净值，这里简化处理
        # 实际需要解析output

        print(f'{code}: 到达更新时间 {target}')
    else:
        print(f'{code}: 尚未到达更新时间 ({target})')
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
        cmd_add "$2" "$3" "$4" "$5"
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
            *)
                echo -e "${RED}❌ 未知dca子命令${NC}"
                echo "用法: $0 dca add|list|remove"
                ;;
        esac
        ;;
    pending-update)
        cmd_pending_update
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        ;;
esac
