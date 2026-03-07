#!/bin/bash
# NanoClaw Service Manager
# Usage: ./nanoclaw.sh [start|stop|restart|status|network]

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_FILE="$HOME/Library/LaunchAgents/com.nanoclaw.plist"
LOG_FILE="$PROJECT_DIR/logs/nanoclaw.log"

# Apple Container 网络配置 (用于容器内访问外网)
setup_network() {
    echo "Checking Apple Container network configuration..."

    # 检查IP转发
    if ! sysctl net.inet.ip.forwarding | grep -q ": 1"; then
        echo "Enabling IP forwarding..."
        sudo sysctl -w net.inet.ip.forwarding=1
    fi

    # 获取默认网络接口
    INTERFACE=$(route get 8.8.8.8 2>/dev/null | grep interface | awk '{print $2}')

    if [ -z "$INTERFACE" ]; then
        echo "Warning: Could not determine network interface"
        return
    fi

    # 检查NAT规则是否已配置
    if ! sudo pfctl -s nat 2>/dev/null | grep -q "192.168.64.0/24"; then
        echo "Configuring NAT for Apple Container (interface: $INTERFACE)..."
        echo "nat on $INTERFACE from 192.168.64.0/24 to any -> ($INTERFACE)" | sudo pfctl -mf -
        echo "NAT configured successfully"
    else
        echo "NAT already configured"
    fi
}

start() {
    echo "Starting NanoClaw..."

    # 配置Apple Container网络
    setup_network

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
    for container_id in $(container ls --quiet 2>/dev/null); do
        if [ "$container_id" != "buildkit" ]; then
            echo "Stopping container: $container_id"
            container stop "$container_id" 2>/dev/null || true
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
    echo "=== Container Status ==="
    container ls 2>/dev/null || echo "Apple Container not running"

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
    network)
        setup_network
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|network}"
        exit 1
        ;;
esac
