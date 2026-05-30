#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🛑 AI 직원 시스템 종료 중..."

for name in llm network telegram; do
    PID_FILE="$DIR/logs/$name.pid"
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            echo "  [$name] 종료 (PID $PID)"
        fi
        rm -f "$PID_FILE"
    fi
done

pkill -f "llama-server" 2>/dev/null || true
pkill -f "agent_network.py" 2>/dev/null || true
pkill -f "telegram_bot.py" 2>/dev/null || true

echo "✅ 종료 완료"
