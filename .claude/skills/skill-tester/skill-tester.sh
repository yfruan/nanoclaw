#!/bin/bash
# Skill Tester - 通用端到端测试框架
# 启动专用测试容器，在容器内执行测试用例

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 项目根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONTAINER_NAME="skill-tester"

# 测试配置
TEST_IMAGE="nanoclaw-agent:latest"
TEST_PORTFOLIO_FILE="${TEST_PORTFOLIO_FILE:-portfolio.test.json}"
CURRENT_GROUP=""
INITIAL_DATA='{"funds":{},"dca":{},"pendingCostUpdate":{}}'

# 标准化测试目录路径
normalize_tests_dir() {
    local tests_dir="$1"
    if [[ "$tests_dir" != /* ]] && [[ "$tests_dir" == container/skills/* ]]; then
        tests_dir="$PROJECT_DIR/$tests_dir"
    fi
    echo "$tests_dir"
}

# 验证 group 参数（防止路径遍历）
validate_group() {
    local group="$1"
    # 只允许字母、数字、下划线、连字符
    if [[ ! "$group" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}❌ 无效的群组名: $group${NC}"
        return 1
    fi
    return 0
}

# 验证环境变量值（防止注入）
validate_env_value() {
    local value="$1"
    # 只允许字母、数字、下划线、连字符、点、斜杠
    if [[ ! "$value" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        return 1
    fi
    return 0
}

# 启动测试容器
start_test_container() {
    local group="$1"

    # 验证 group 参数
    validate_group "$group" || return 1

    echo -e "${CYAN}启动测试容器...${NC}"

    # 尝试使用已停止的测试容器
    local existing_container
    existing_container=$(container ls -a --format '{{.Names}}' 2>/dev/null | grep -E '^skill-tester$' | head -1 || true)

    if [ -n "$existing_container" ]; then
        echo -e "${CYAN}使用已存在的容器: $existing_container${NC}"
        if ! container start "$existing_container" 2>/dev/null; then
            echo -e "${YELLOW}启动失败，尝试重新创建...${NC}"
            container rm "$existing_container" 2>/dev/null || true
        else
            CONTAINER_NAME="$existing_container"
            # 等待容器就绪
            wait_for_container || return 1
            echo -e "${GREEN}容器已启动: $CONTAINER_NAME${NC}"
            return 0
        fi
    fi

    # 停止并删除旧容器（如果存在）
    container stop "$CONTAINER_NAME" 2>/dev/null || true
    container rm "$CONTAINER_NAME" 2>/dev/null || true

    # 启动新容器，挂载项目目录
    # 使用 --entrypoint 覆盖默认入口，避免 nanoclaw-agent 的 entrypoint 问题
    # 挂载 groups/$group 到 /workspace/group/$group，保持目录结构通用
    container run -d \
        --name "$CONTAINER_NAME" \
        --entrypoint /bin/sh \
        -v "$PROJECT_DIR:/workspace:rw" \
        -v "$PROJECT_DIR/groups/$group:/workspace/group/$group:rw" \
        "$TEST_IMAGE" \
        -c "while true; do sleep 1; done"

    # 等待容器就绪
    wait_for_container || return 1

    echo -e "${GREEN}容器已启动: $CONTAINER_NAME${NC}"
}

# 等待容器就绪
wait_for_container() {
    local max_attempts=10
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if container exec "$CONTAINER_NAME" echo "ok" >/dev/null 2>&1; then
            return 0
        fi
        echo -e "${CYAN}等待容器启动... ($attempt/$max_attempts)${NC}"
        sleep 1
        attempt=$((attempt + 1))
    done

    echo -e "${RED}❌ 容器启动超时${NC}"
    return 1
}

# 初始化测试数据
init_test_data() {
    local group="$1"
    local portfolio_file="/workspace/group/$group/$TEST_PORTFOLIO_FILE"

    container exec "$CONTAINER_NAME" bash -c "rm -f \"$portfolio_file\""
    container exec "$CONTAINER_NAME" bash -c "mkdir -p \"\$(dirname \"$portfolio_file\")\""
    container exec "$CONTAINER_NAME" bash -c "echo '$INITIAL_DATA' > \"$portfolio_file\""

    echo -e "${CYAN}测试模式: 使用 $portfolio_file${NC}"
}

# 停止测试容器
stop_test_container() {
    echo -e "${CYAN}清理测试文件...${NC}"
    # 清理测试数据文件
    if [ -n "$CURRENT_GROUP" ]; then
        local portfolio_file="/workspace/group/$CURRENT_GROUP/$TEST_PORTFOLIO_FILE"
        container exec "$CONTAINER_NAME" bash -c "rm -f \"$portfolio_file\"" 2>/dev/null || true
    fi
    echo -e "${GREEN}测试文件已清理${NC}"

    echo -e "${CYAN}清理测试容器...${NC}"
    container stop "$CONTAINER_NAME" 2>/dev/null || true
    container rm "$CONTAINER_NAME" 2>/dev/null || true
    echo -e "${GREEN}容器已清理${NC}"

    # 重置全局变量
    CURRENT_GROUP=""
}

# 列出测试用例
cmd_list() {
    local tests_dir
    tests_dir=$(normalize_tests_dir "$1")

    if [ -z "$tests_dir" ] || [ ! -d "$tests_dir" ]; then
        echo -e "${YELLOW}测试目录不存在: $tests_dir${NC}"
        return 1
    fi

    echo -e "${BLUE}可用测试用例:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for file in "$tests_dir"/*.json; do
        [ -f "$file" ] || continue
        local filename=$(basename "$file")
        echo -e "${CYAN}$filename${NC}"

        python3 -c "
import json
with open('$file', 'r') as f:
    try:
        tests = json.load(f)
        if isinstance(tests, list):
            for t in tests:
                name = t.get('name', 'unnamed')
                test_type = t.get('type', 'command')
                print(f'  - {name} [{test_type}]')
        elif isinstance(tests, dict):
            for name, t in tests.items():
                test_type = t.get('type', 'command')
                print(f'  - {name} [{test_type}]')
    except json.JSONDecodeError:
        pass
" 2>/dev/null || true
    done
}

# 运行所有测试
run_all_tests() {
    local tests_dir
    local group="$2"
    CURRENT_GROUP="$group"

    if [ -z "$group" ]; then
        echo -e "${RED}❌ 请指定群组名 (group)${NC}"
        echo "用法: $0 run <tests_dir> <group>"
        return 1
    fi

    tests_dir=$(normalize_tests_dir "$1")

    if [ -z "$tests_dir" ] || [ ! -d "$tests_dir" ]; then
        echo -e "${YELLOW}测试目录不存在: $tests_dir${NC}"
        return 1
    fi

    # 读取全局配置文件（可选）
    local global_config_file="$tests_dir/config.json"
    if [ -f "$global_config_file" ]; then
        echo -e "${CYAN}读取全局配置文件: $global_config_file${NC}"
        while IFS='=' read -r key value; do
            export "$key=$value"
        done < <(python3 -c "
import json
with open('$global_config_file', 'r') as f:
    config = json.load(f)
    if 'env' in config:
        for k, v in config['env'].items():
            print(f'{k}={v}')
")
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}       运行测试: $(basename "$tests_dir")${NC}"
    echo -e "${BLUE}========================================${NC}"

    # 启动测试容器
    start_test_container "$group" || return 1

    # 初始化测试数据
    init_test_data "$group"

    local total=0
    local passed=0
    local failed=0

    # 遍历所有测试文件（排除配置文件）
    for test_file in "$tests_dir"/*.json; do
        [ -f "$test_file" ] || continue
        # 跳过配置文件 (config.json 和 *.config.json)
        local basename=$(basename "$test_file")
        [[ "$basename" == "config.json" ]] && continue
        [[ "$basename" == *.config.json ]] && continue

        echo -e "${CYAN}测试文件: $(basename "$test_file")${NC}"

        # 读取该测试文件的配置文件（可选）
        local test_basename=$(basename "$test_file" .json)
        local test_config_file="$tests_dir/$test_basename.config.json"
        local shared_setup=""

        if [ -f "$test_config_file" ]; then
            echo -e "${CYAN}读取配置: $test_config_file${NC}"
            while IFS='=' read -r key value; do
                export "$key=$value"
            done < <(python3 -c "
import json
with open('$test_config_file', 'r') as f:
    config = json.load(f)
    if 'env' in config:
        for k, v in config['env'].items():
            print(f'{k}={v}')
    if 'shared_setup' in config:
        print('SHARED_SETUP=' + config['shared_setup'])
")
            shared_setup="${SHARED_SETUP:-}"
        fi

        # 执行组级别共享 setup（如果配置了）
        if [ -n "$shared_setup" ]; then
            echo -e "${CYAN}执行共享初始化...${NC}"
            container exec "$CONTAINER_NAME" bash -c "$shared_setup" || true
        fi

        # 使用 Python 解析并执行测试
        local results
        results=$(python3 -c "
import json
import subprocess
import sys
import os
import re

container_name = '$CONTAINER_NAME'

total = 0
passed = 0
failed = 0

with open('$test_file', 'r') as f:
    tests = json.load(f)

if not isinstance(tests, list):
    tests = [tests]

for t in tests:
    name = t.get('name', 'unnamed')
    command = t.get('command', '')
    expect = t.get('expect', {})
    contains = expect.get('contains')
    timeout = t.get('timeout', 30)

    if not command:
        continue

    total += 1

    # 执行命令
    try:
        result = subprocess.run(
            ['container', 'exec', container_name, 'bash', '-c', command],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        output = result.stdout + result.stderr
        exit_code = result.returncode
    except subprocess.TimeoutExpired:
        output = 'TIMEOUT'
        exit_code = 124
    except Exception as e:
        output = str(e)
        exit_code = 1

    # 验证
    success = False
    if isinstance(contains, list):
        success = all(c in output for c in contains)
    elif isinstance(contains, str):
        success = contains in output

    if success:
        passed += 1
        print(f'✓ {name}')
    else:
        failed += 1
        print(f'✗ {name}')
        if contains:
            print(f'  Expected: {contains}')
        print(f'  Output: {output[:200]}')

print(f'TOTAL:{total}')
print(f'PASSED:{passed}')
print(f'FAILED:{failed}')
" 2>&1) || true

        echo "$results"

        # 统计结果
        total=$((total + $(echo "$results" | grep -oE 'TOTAL:[0-9]+' | grep -oE '[0-9]+' || echo 0)))
        passed=$((passed + $(echo "$results" | grep -oE 'PASSED:[0-9]+' | grep -oE '[0-9]+' || echo 0)))
        failed=$((failed + $(echo "$results" | grep -oE 'FAILED:[0-9]+' | grep -oE '[0-9]+' || echo 0)))
    done

    # 汇总结果
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "总计: $total | ${GREEN}通过: $passed${NC} | ${RED}失败: $failed${NC}"
    echo -e "${BLUE}========================================${NC}"

    # 停止容器
    stop_test_container

    [ $failed -eq 0 ]
}

# 运行单个测试
run_single_test() {
    local tests_dir="$1"
    local test_name="$2"
    local group="$3"
    CURRENT_GROUP="$group"

    if [ -z "$tests_dir" ] || [ -z "$test_name" ]; then
        echo -e "${RED}❌ 参数不全${NC}"
        echo "用法: $0 run <tests_dir> <测试名称> <group>"
        return 1
    fi

    if [ -z "$group" ]; then
        echo -e "${RED}❌ 请指定群组名 (group)${NC}"
        echo "用法: $0 run <tests_dir> <测试名称> <group>"
        return 1
    fi

    # 验证 group 参数
    validate_group "$group" || return 1

    tests_dir=$(normalize_tests_dir "$tests_dir")

    echo -e "${BLUE}运行测试: $test_name${NC}"

    # 启动测试容器
    start_test_container "$group" || return 1

    # 初始化测试数据
    init_test_data "$group"

    # 查找并执行指定测试
    python3 -c "
import json
import subprocess
import sys

container_name = '$CONTAINER_NAME'
tests_dir = '$tests_dir'
test_name = '$test_name'

# 遍历所有测试文件查找匹配的测试
tests = []
import glob
for f in sorted(glob.glob(tests_dir + '/*.json')):
    if f.endswith('config.json'):
        continue
    try:
        with open(f, 'r') as fp:
            t = json.load(fp)
            if isinstance(t, list):
                tests.extend(t)
            else:
                tests.append(t)
    except:
        pass

if not tests:
    print('No tests found')
    sys.exit(1)

if not isinstance(tests, list):
    tests = [tests]

for t in tests:
    if t.get('name') == test_name:
        command = t.get('command', '')
        expect = t.get('expect', {})
        contains = expect.get('contains')
        timeout = t.get('timeout', 30)

        print(f'Command: {command}')

        result = subprocess.run(
            ['container', 'exec', container_name, 'bash', '-c', command],
            capture_output=True,
            text=True,
            timeout=timeout
        )

        output = result.stdout + result.stderr

        print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)

        success = False
        if isinstance(contains, list):
            success = all(c in output for c in contains)
        elif isinstance(contains, str):
            success = contains in output
        else:
            success = result.returncode == 0

        if success:
            print('✓ 测试通过')
        else:
            print('✗ 测试失败')
            sys.exit(1)
        break
"

    # 停止容器
    stop_test_container
}

# 显示帮助
show_help() {
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Skill Tester - 通用测试框架       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "命令:"
    echo "  list <tests_dir>              列出测试用例"
    echo "  run <tests_dir> <group>       运行所有测试"
    echo "  run <tests_dir> <name> <group> 运行单个测试"
    echo ""
    echo "参数:"
    echo "  tests_dir   测试目录"
    echo "  group       群组名 (必须)"
    echo ""
    echo "示例:"
    echo "  $0 list container/skills/fin-assistant/etf-assistant/tests"
    echo "  $0 run container/skills/fin-assistant/etf-assistant/tests fin-assistant"
    echo ""
    echo "注意:"
    echo "  - 启动专用测试容器运行测试"
    echo "  - 测试完成后自动清理容器"
    echo "  - 支持 MCP 工具调用"
}

# 主逻辑
case "$1" in
    list)
        cmd_list "$2"
        ;;
    run)
        if [ -z "$2" ]; then
            echo -e "${RED}❌ 参数不全${NC}"
            show_help
        else
            # 判断是运行单个测试还是全部测试
            # run <tests_dir> <group> - 运行所有测试
            # run <tests_dir> <name> <group> - 运行单个测试
            if [ -n "$4" ]; then
                run_single_test "$2" "$3" "$4"
            elif [ -n "$3" ]; then
                run_all_tests "$2" "$3"
            else
                echo -e "${RED}❌ 参数不全${NC}"
                show_help
            fi
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        ;;
esac
