#!/bin/bash
# ============================================================
# Vulkan 모드로 AI 직원 시스템 기동 (AMD GPU 가속)
#
# 사전 조건:
#   1. build_vulkan.sh 실행 완료
#   2. test_gpu.sh 로 GPU 인식 확인 (backend=Vulkan + t/s 표시)
#
# test_gpu.sh 에서 어느 Device 가 AMD GPU 인지 확인 후
# VULKAN_DEVICE 값을 아래에 설정하세요 (보통 0 또는 1).
# ============================================================
set -e

VULKAN_DEVICE="${VULKAN_DEVICE:-1}"   # AMD 5700 XT 는 보통 device 1

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/logs"
mkdir -p "$LOG"

source "$DIR/venv/bin/activate"

if [ ! -f "$DIR/config.py" ]; then
    echo "❌ config.py 없음. 먼저 setup.sh 실행 후 config.py 작성."
    exit 1
fi

MODEL=$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.expanduser(MODEL_MAIN))")
if [ ! -f "$MODEL" ]; then
    echo "❌ 모델 파일 없음: $MODEL"
    exit 1
fi

LLAMA_DIR="$HOME/llama.cpp"
VK_BIN="$LLAMA_DIR/build-vulkan/bin/llama-server"
if [ ! -x "$VK_BIN" ]; then
    echo "❌ Vulkan 바이너리 없음: $VK_BIN"
    echo "   build_vulkan.sh 를 먼저 실행하세요."
    exit 1
fi

BREW_PREFIX="$(brew --prefix)"
VK_ICD="$BREW_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json"
if [ ! -f "$VK_ICD" ]; then
    ALT=$(find "$BREW_PREFIX" -name "MoltenVK_icd.json" 2>/dev/null | head -1)
    VK_ICD="${ALT:-$VK_ICD}"
fi

export VK_ICD_FILENAMES="$VK_ICD"
export GGML_VK_VISIBLE_DEVICES="$VULKAN_DEVICE"
export DYLD_LIBRARY_PATH="$LLAMA_DIR/build-vulkan/bin:/usr/local/lib:$DYLD_LIBRARY_PATH"

echo "🚀 AI 직원 시스템 기동 중 (Vulkan GPU 모드)..."
echo "   모델:       $MODEL"
echo "   바이너리:   $VK_BIN"
echo "   VK Device:  $VULKAN_DEVICE (AMD 5700 XT)"
echo "   ICD:        $VK_ICD"

pkill -9 -f "llama-server" 2>/dev/null || true
sleep 1

"$VK_BIN" \
    -m "$MODEL" \
    -ngl 99 \
    -c 4096 \
    --no-warmup \
    --host 0.0.0.0 \
    --port 11434 \
    --metrics \
    > "$LOG/llm.log" 2>&1 &
LLM_PID=$!
echo "  [1/3] Vulkan LLM 서버 시작 (PID $LLM_PID)"

echo "  LLM 서버 준비 대기 중..."
for i in $(seq 1 30); do
    if curl -s http://localhost:11434/health > /dev/null 2>&1; then
        echo "  ✅ LLM 서버 준비 완료"
        break
    fi
    sleep 2
done

# Vulkan 실제 사용 확인
BACKEND=$(curl -s http://localhost:11434/props 2>/dev/null | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('default_generation_settings',{}).get('model','?'))" \
    2>/dev/null || echo "확인 불가")
echo "  LLM 모델: $BACKEND"

python "$DIR/agent_network.py" > "$LOG/network.log" 2>&1 &
NET_PID=$!
echo "  [2/3] 네트워크 서버 시작 (PID $NET_PID)"

python "$DIR/telegram_bot.py" > "$LOG/telegram.log" 2>&1 &
TG_PID=$!
echo "  [3/3] 텔레그램 봇 시작 (PID $TG_PID)"

echo "$LLM_PID" > "$DIR/logs/llm.pid"
echo "$NET_PID" > "$DIR/logs/network.pid"
echo "$TG_PID"  > "$DIR/logs/telegram.pid"

echo ""
echo "✅ Vulkan 모드 가동 완료"
echo "   로그: tail -f $LOG/llm.log"
echo "   종료: ./stop.sh"
echo ""
echo "  llm.log 에서 아래를 확인하세요:"
echo "    'Vulkan' 또는 'ggml_vulkan' → GPU 가속 성공"
echo "    'BLAS' 또는 'CPU' → GPU 미인식, start.sh 로 복귀"

wait
