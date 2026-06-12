#!/bin/bash
# 시스템 상태 한눈에 확인

DIR="$(cd "$(dirname "$0")" && pwd)"

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

# 현재 모델
MODEL_FILE=$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.basename(os.path.expanduser(MODEL_MAIN)))" 2>/dev/null || echo "알 수 없음")
echo "  모델:  $MODEL_FILE"

# GPU 진단 결과
GPU_STATUS="미진단 (bash fix_gpu.sh 실행 권장)"
GPU_NOTE=""
if [ -f "$DIR/gpu.env" ]; then
    # shellcheck source=/dev/null
    source "$DIR/gpu.env"
    if [ "${GPU_OK:-0}" = "1" ]; then
        GPU_STATUS="✅ Vulkan 활성화 (VK_DEVICE=${VK_DEVICE:-자동})"
    else
        GPU_STATUS="❌ macOS GPU 추론 불가 (CPU 전용)"
        GPU_NOTE="     Intel Mac + RDNA1: Metal 버그(#19563), Vulkan 0 t/s(#20104)"
    fi
fi
echo "  GPU:   AMD Radeon Pro 5700 XT 16GB"
echo "         $GPU_STATUS"
[ -n "$GPU_NOTE" ] && echo "$GPU_NOTE"

# 시스템 리소스
echo "  CPU:   i9-10900K — $(sysctl -n hw.physicalcpu)코어 $(sysctl -n hw.logicalcpu)스레드"
MEM=$(vm_stat | awk '
  /Pages free/         { free=$3 }
  /Pages active/       { active=$3 }
  /Pages wired/        { wired=$4 }
  END { printf "%.1f GB used", (active+wired)*4096/1024/1024/1024 }
')
echo "  RAM:   $MEM / 80GB"
echo "  시각:  $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
