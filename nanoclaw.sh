#!/bin/bash
# NanoClaw Service Manager
# Usage: ./nanoclaw.sh [start|stop|restart|status|build]

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_FILE="$HOME/Library/LaunchAgents/com.nanoclaw.plist"
LOG_FILE="$PROJECT_DIR/logs/nanoclaw.log"

# 设置群组 Ollama 模型
model_set() {
    local group_name="$1"
    local model_name="$2"

    if [ -z "$group_name" ] || [ -z "$model_name" ]; then
        echo "Usage: $0 model set <group-name> <model-name>"
        echo "Example: $0 model set fin-assistant qwen3.5:9b"
        exit 1
    fi

    local model_dir="$PROJECT_DIR/data/sessions/$group_name/.claude"
    local model_file="$model_dir/model.json"

    # 确保目录存在
    mkdir -p "$model_dir"

    # 创建 model.json
    cat > "$model_file" << EOF
{
  "provider": "ollama",
  "model": "$model_name"
}
EOF

    echo "Model set: $group_name -> $model_name"
    echo "Created: $model_file"
}

# 删除群组 Ollama 模型配置
model_unset() {
    local group_name="$1"

    if [ -z "$group_name" ]; then
        echo "Usage: $0 model unset <group-name>"
        echo "Example: $0 model unset fin-assistant"
        exit 1
    fi

    local model_file="$PROJECT_DIR/data/sessions/$group_name/.claude/model.json"

    if [ -f "$model_file" ]; then
        rm "$model_file"
        echo "Model unset: $group_name"
        echo "Removed: $model_file"
    else
        echo "No model config found for group: $group_name"
    fi
}

# 启动本地 Ollama 服务
ollama_run() {
    # 检查 ollama serve 是否已运行
    if pgrep -f "ollama serve" > /dev/null; then
        echo "Ollama serve is already running"
        return 0
    fi

    echo "Starting Ollama serve..."
    open -a Ollama
    sleep 2
    echo "Ollama started"
}

# 停止本地 Ollama
ollama_stop() {
    if pgrep -f "ollama serve" > /dev/null; then
        pkill -f "ollama serve"
        echo "Ollama stopped"
    else
        echo "Ollama is not running"
    fi
}

# 查看 Ollama 状态
ollama_status() {
    if pgrep -f "ollama serve" > /dev/null; then
        echo "Ollama is running"
        ps aux | grep "ollama serve" | grep -v grep
    else
        echo "Ollama is not running"
    fi
}

build() {
    echo "Building NanoClaw..."

    cd "$PROJECT_DIR"

    # 编译 TypeScript
    echo "Building TypeScript..."
    npm run build

    # 构建容器镜像
    echo "Building container image..."
    ./container/build.sh

    echo "Build complete"
}

start() {
    echo "Starting NanoClaw..."

    # 清理可能遗留的开发进程（tsx、node src/index.ts）
    echo "Cleaning up stale dev processes..."
    pkill -f "tsx.*src/index" 2>/dev/null || true
    pkill -f "node.*src/index\.ts" 2>/dev/null || true

    cd "$PROJECT_DIR"
    npm run build
    mkdir -p "$PROJECT_DIR/logs"
    launchctl load "$PLIST_FILE"
    echo "NanoClaw started"
}

stop() {
    echo "Stopping NanoClaw..."
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    echo "NanoClaw stopped"

    # 清理残留的开发进程
    echo "Cleaning up stale dev processes..."
    pkill -f "tsx.*src/index" 2>/dev/null || true
    pkill -f "node.*src/index\.ts" 2>/dev/null || true
    pkill -f "node dist/index.js" 2>/dev/null || true

    # 清理残留容器
    echo "Cleaning up orphaned containers..."
    docker ps --filter name=nanoclaw- --format '{{.Names}}' | while read -r container_id; do
        if [ -n "$container_id" ]; then
            echo "Stopping container: $container_id"
            docker stop "$container_id" 2>/dev/null || true
        fi
    done
}

restart() {
    stop
    sleep 2
    start
}

status() {
    echo "=== Service Status ==="
    if launchctl list | grep -q "com.nanoclaw"; then
        launchctl list | grep nanoclaw
    else
        echo "Service not loaded"
    fi

    echo ""
    echo "=== Docker Status ==="
    docker ps 2>/dev/null || echo "Docker is not running"

    echo ""
    echo "=== Recent Logs ==="
    if [ -f "$LOG_FILE" ]; then
        tail -5 "$LOG_FILE"
    else
        echo "No log file found"
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    build)
        build
        ;;
    model)
        case "$2" in
            set)
                model_set "$3" "$4"
                ;;
            unset)
                model_unset "$3"
                ;;
            *)
                echo "Usage: $0 model {set|unset} [args]"
                echo "  set <group-name> <model-name>  - Set Ollama model for group"
                echo "  unset <group-name>            - Remove model config for group"
                echo ""
                echo "Examples:"
                echo "  $0 model set fin-assistant qwen3.5:9b"
                echo "  $0 model unset fin-assistant"
                exit 1
                ;;
        esac
        ;;
    help)
        echo "NanoClaw Service Manager"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        printf "  %-30s %s\n" "start" "Start NanoClaw service"
        printf "  %-30s %s\n" "stop" "Stop NanoClaw service"
        printf "  %-30s %s\n" "restart" "Restart NanoClaw service"
        printf "  %-30s %s\n" "status" "Show service status"
        printf "  %-30s %s\n" "build" "Build TypeScript and container image"
        printf "  %-30s %s\n" "model set <group> <model>" "Set Ollama model for group"
        printf "  %-30s %s\n" "model unset <group>" "Remove model config for group"
        printf "  %-30s %s\n" "ollama start" "Start Ollama serve"
        printf "  %-30s %s\n" "ollama stop" "Stop Ollama"
        printf "  %-30s %s\n" "ollama status" "Show Ollama status"
        printf "  %-30s %s\n" "help" "Show this help message"
        ;;
    ollama)
        case "$2" in
            start|run)
                ollama_run
                ;;
            stop)
                ollama_stop
                ;;
            status)
                ollama_status
                ;;
            *)
                echo "Usage: $0 ollama {start|stop|status}"
                echo "  start  Start Ollama serve (API server)"
                echo "  stop   Stop Ollama"
                echo "  status Show status"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|build|model|ollama|help}"
        echo "Run '$0 help' for more information"
        exit 1
        ;;
esac
