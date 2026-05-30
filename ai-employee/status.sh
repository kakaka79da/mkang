#!/bin/bash
# 시스템 상태 한눈에 확인

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AI 직원 시스템 상태"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# LLM 서버
if curl -s http://localhost:11434/health > /dev/null 2>&1; then
    echo "  🟢 LLM 서버    http://localhost:11434"
    curl -s http://localhost:11434/metrics 2>/dev/null | grep -E "^prompt|^tokens" | head -3 | sed 's/^/     /'
else
    echo "  🔴 LLM 서버    중지됨"
fi

# Agent API
if curl -s http://localhost:8000/health > /dev/null 2>&1; then
    echo "  🟢 Agent API   http://localhost:8000"
else
    echo "  🔴 Agent API   중지됨"
fi

# 텔레그램 봇
if pgrep -f "telegram_bot.py" > /dev/null; then
    echo "  🟢 텔레그램 봇 실행 중"
else
    echo "  🔴 텔레그램 봇 중지됨"
fi

echo ""

# 시스템 리소스
echo "  CPU:   $(top -l 1 | awk '/CPU usage/{print $3, $4, $5, $6}')"
MEM=$(vm_stat | awk '
  /Pages free/         { free=$3 }
  /Pages active/       { active=$3 }
  /Pages wired/        { wired=$4 }
  END { printf "%.1f GB used", (active+wired)*4096/1024/1024/1024 }
')
echo "  RAM:   $MEM / 80GB"
echo "  GPU:   AMD Radeon Pro 5700 XT 16GB"
echo "  시각:  $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
