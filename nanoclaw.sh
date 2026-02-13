#!/bin/bash
# NanoClaw Service Manager
# Usage: ./nanoclaw.sh [start|stop|restart|status]

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_FILE="$HOME/Library/LaunchAgents/com.nanoclaw.plist"
LOG_FILE="$PROJECT_DIR/logs/nanoclaw.log"

start() {
    echo "Starting NanoClaw..."
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

    # 清理残留容器（可选）
    if command -v container &> /dev/null; then
        echo "Cleaning up orphaned containers..."
        container ls -a 2>/dev/null | grep "nanoclaw-agent" | awk '{print $1}' | while read id; do
            container stop "$id" 2>/dev/null || true
        done
    fi
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
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
