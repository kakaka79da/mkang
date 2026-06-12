#!/bin/bash
# AI 직원 시스템 기동 — Linux(Ubuntu) + ROCm GPU 버전
# systemd(ai-employee.service)가 이 스크립트를 실행한다.
# GPU(-ngl 99) 기동 실패 시 CPU 모드로 자동 폴백.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/logs"
mkdir -p "$LOG"
cd "$DIR"
source "$DIR/venv/bin/activate"

# GPU 아키텍처별 ROCm 설정: gfx1010(5700 XT)만 우회 필요, gfx906(Vega 48)은 불필요
GFX=$(/opt/rocm/bin/rocminfo 2>/dev/null | grep -m1 -oE 'gfx[0-9a-f]+' || true)
case "$GFX" in gfx101*) export HSA_OVERRIDE_GFX_VERSION=10.1.0 ;; esac

LLAMA_DIR="$HOME/llama.cpp"
BIN="$LLAMA_DIR/build-rocm/bin/llama-server"
[ -x "$BIN" ] || BIN="$(command -v llama-server)"

MODEL=$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.expanduser(MODEL_MAIN))")
[ -f "$MODEL" ] || { echo "모델 없음: $MODEL"; exit 1; }

pkill -9 -f "llama-server" 2>/dev/null || true
pkill -f "agent_network.py" 2>/dev/null || true
pkill -f "telegram_bot.py" 2>/dev/null || true
sleep 1

start_llm() {
    local ngl="$1"
    "$BIN" \
        -m "$MODEL" \
        -ngl "$ngl" \
        -c 8192 \
        --flash-attn \
        --host 0.0.0.0 \
        --port 11434 \
        --metrics \
        > "$LOG/llm.log" 2>&1 &
    echo $!
}

wait_server() {
    for i in $(seq 1 "${1:-45}"); do
        curl -s http://localhost:11434/health >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# GPU 우선, 실패 시 CPU 폴백
MODE="ROCm GPU"
LLM_PID=$(start_llm 99)
if ! wait_server 45; then
    echo "GPU 기동 실패 — CPU 모드로 폴백" >&2
    kill "$LLM_PID" 2>/dev/null || true
    pkill -9 -f "llama-server" 2>/dev/null || true
    sleep 1
    MODE="CPU"
    LLM_PID=$(start_llm 0)
    wait_server 45 || { echo "LLM 서버 시작 실패: tail $LOG/llm.log"; exit 1; }
fi
echo "LLM 서버 준비 완료 [$MODE] PID $LLM_PID"

python "$DIR/agent_network.py" > "$LOG/network.log" 2>&1 &
NET_PID=$!
python "$DIR/telegram_bot.py" > "$LOG/telegram.log" 2>&1 &
TG_PID=$!

echo "$LLM_PID" > "$LOG/llm.pid"
echo "$NET_PID" > "$LOG/network.pid"
echo "$TG_PID"  > "$LOG/telegram.pid"
echo "AI 직원 시스템 가동 [$MODE] — LLM:$LLM_PID NET:$NET_PID TG:$TG_PID"

# systemd 가 프로세스를 추적하도록 포그라운드 유지
wait
