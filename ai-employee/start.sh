#!/bin/bash
# AI 직원 시스템 기동 스크립트
# GPU 우선 전략: Vulkan(AMD 5700 XT) 시도 → 실패 시 CPU 폴백
#
# [GPU 전략]
# - Metal 백엔드: AMD RDNA1 에서 gibberish 출력 버그 (llama.cpp #19563, 미수정)
# - Vulkan/MoltenVK: GGML_VK_VISIBLE_DEVICES=1 로 AMD GPU(device 1) 지정
# - CPU: i9-10900K 10코어, MoE 모델 기준 10~15 t/s

set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/logs"
mkdir -p "$LOG"

# ── 사전 확인 ────────────────────────────────────────────────────────────────
cd "$DIR"
source "$DIR/venv/bin/activate"

if [ ! -f "$DIR/config.py" ]; then
    fail "config.py 가 없습니다."
    echo "  cp $DIR/config.example.py $DIR/config.py  후 설정하세요."
    exit 1
fi

MODEL=$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.expanduser(MODEL_MAIN))")
if [ ! -f "$MODEL" ]; then
    fail "모델 파일 없음: $MODEL"
    echo "  switch_model.sh 또는 setup.sh 를 먼저 실행하세요."
    exit 1
fi

echo "=================================================="
echo "  AI 직원 시스템 기동"
echo "  모델: $(basename "$MODEL")"
echo "=================================================="

# ── 기존 서버 정리 ───────────────────────────────────────────────────────────
pkill -9 -f "llama-server" 2>/dev/null || true
sleep 1

# ── Vulkan 환경 준비 ─────────────────────────────────────────────────────────
LLAMA_DIR="$HOME/llama.cpp"
VK_BIN="$LLAMA_DIR/build-vulkan/bin/llama-server"
CPU_BIN=""
if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    CPU_BIN="$LLAMA_DIR/build/bin/llama-server"
else
    CPU_BIN="$(command -v llama-server 2>/dev/null || echo "")"
fi

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /usr/local)"
VK_ICD="$BREW_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json"
if [ ! -f "$VK_ICD" ]; then
    ALT="$(find "$BREW_PREFIX" -name "MoltenVK_icd.json" 2>/dev/null | head -1)"
    [ -n "$ALT" ] && VK_ICD="$ALT"
fi

# ── LLM 서버 기동 함수 ───────────────────────────────────────────────────────
# 주의: 이 함수들은 $(...) 로 PID 를 받아가므로, stdout 에는 PID 한 줄만
# 출력해야 한다. 안내 메시지는 반드시 stderr(>&2)로 보낸다.
start_cpu() {
    local bin="${1:-$CPU_BIN}"
    export DYLD_LIBRARY_PATH="$LLAMA_DIR/build/bin:/usr/local/lib:$DYLD_LIBRARY_PATH"
    CPU_CORES="$(sysctl -n hw.physicalcpu)"
    CPU_THREADS="$(sysctl -n hw.logicalcpu)"
    info "CPU 모드 시작 (${CPU_CORES}코어 생성 / ${CPU_THREADS}스레드 배치)" >&2
    "$bin" \
        -m "$MODEL" \
        -ngl 0 \
        -t "$CPU_CORES" \
        -tb "$CPU_THREADS" \
        -c 8192 \
        -b 512 \
        --no-warmup \
        --host 0.0.0.0 \
        --port 11434 \
        --metrics \
        > "$LOG/llm.log" 2>&1 &
    echo $!
}

start_vulkan() {
    export VK_ICD_FILENAMES="$VK_ICD"
    # 장치 선택: fix_gpu.sh 진단 결과(gpu.env 의 VK_DEVICE)를 따른다.
    # 비어 있으면 필터 없이 전체 장치 사용 (아이맥은 AMD 가 유일 장치)
    if [ -n "${VK_DEVICE:-}" ]; then
        export GGML_VK_VISIBLE_DEVICES="$VK_DEVICE"
    else
        unset GGML_VK_VISIBLE_DEVICES
    fi
    export DYLD_LIBRARY_PATH="$LLAMA_DIR/build-vulkan/bin:/usr/local/lib:$DYLD_LIBRARY_PATH"
    info "Vulkan GPU 모드 시도 (AMD Radeon Pro 5700 XT)" >&2
    "$VK_BIN" \
        -m "$MODEL" \
        -ngl 99 \
        -c 4096 \
        --no-warmup \
        --host 0.0.0.0 \
        --port 11434 \
        --metrics \
        > "$LOG/llm.log" 2>&1 &
    echo $!
}

wait_server() {
    local max="${1:-25}"
    for i in $(seq 1 "$max"); do
        if curl -s http://localhost:11434/health > /dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# ── ① LLM 서버: GPU 우선, CPU 폴백 ──────────────────────────────────────────
GPU_MODE="CPU"
LLM_PID=""

# fix_gpu.sh 진단 결과가 있으면 따른다 (GPU_OK=0 이면 GPU 시도 생략)
VK_DEVICE=""
TRY_GPU=1
if [ -f "$DIR/gpu.env" ]; then
    source "$DIR/gpu.env"
    if [ "${GPU_OK:-1}" = "0" ]; then
        TRY_GPU=0
        echo "  (gpu.env: 진단 결과 GPU 불가 — CPU 모드로 바로 시작)"
    fi
fi

if [ "$TRY_GPU" = "1" ] && [ -x "$VK_BIN" ] && [ -f "$VK_ICD" ]; then
    echo ""
    info "Vulkan 바이너리 발견 — GPU 기동 시도"
    LLM_PID=$(start_vulkan)
    echo "  PID $LLM_PID — 최대 30초 대기..."

    if wait_server 15; then
        # 서버가 올라왔으면 실제 Vulkan 사용 여부 확인
        if grep -qiE "ggml_vulkan|vk device" "$LOG/llm.log" 2>/dev/null; then
            ok "Vulkan AMD GPU 활성화!"
            GPU_MODE="Vulkan"
        else
            echo "  서버는 기동됐지만 Vulkan GPU 미인식 (BLAS/CPU 폴백)"
            echo "  → CPU 모드로 전환합니다"
            kill "$LLM_PID" 2>/dev/null || true
            pkill -9 -f "llama-server" 2>/dev/null || true
            sleep 1
            LLM_PID=$(start_cpu)
        fi
    else
        echo "  Vulkan 서버 타임아웃 — CPU 모드로 전환합니다"
        kill "$LLM_PID" 2>/dev/null || true
        pkill -9 -f "llama-server" 2>/dev/null || true
        sleep 1
        LLM_PID=$(start_cpu)
    fi
else
    [ ! -x "$VK_BIN" ] && echo "  (Vulkan 바이너리 없음 — build_vulkan.sh 로 빌드 가능)"
    [ ! -f "$VK_ICD" ] && echo "  (MoltenVK 없음 — brew install molten-vk)"
    LLM_PID=$(start_cpu)
fi

echo "  LLM 서버 PID: $LLM_PID — 준비 대기 중..."
if wait_server 30; then
    ok "LLM 서버 준비 완료 [$GPU_MODE 모드]"
else
    fail "LLM 서버 시작 실패. 로그 확인: tail -50 $LOG/llm.log"
    exit 1
fi

# ── ② 에이전트 네트워크 API ──────────────────────────────────────────────────
cd "$DIR"
python "$DIR/agent_network.py" > "$LOG/network.log" 2>&1 &
NET_PID=$!
info "네트워크 서버 시작 (PID $NET_PID)"

# ── ③ 텔레그램 봇 ───────────────────────────────────────────────────────────
python "$DIR/telegram_bot.py" > "$LOG/telegram.log" 2>&1 &
TG_PID=$!
info "텔레그램 봇 시작 (PID $TG_PID)"

# PID 저장
echo "$LLM_PID" > "$LOG/llm.pid"
echo "$NET_PID" > "$LOG/network.pid"
echo "$TG_PID"  > "$LOG/telegram.pid"

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
ok "AI 직원 시스템 가동 완료"
echo "  GPU 모드:  $GPU_MODE"
echo "  모델:      $(basename "$MODEL")"
echo "  LLM:       http://localhost:11434"
echo "  Agent API: http://localhost:8000"
echo "  로그:      $LOG/"
echo ""
if [ "$GPU_MODE" = "CPU" ]; then
    echo "  GPU 가속이 필요하면:"
    echo "    bash $DIR/build_vulkan.sh   ← Vulkan 빌드"
    echo "    bash $DIR/test_gpu.sh       ← GPU 인식 확인"
fi
echo "  종료: bash $DIR/stop.sh"
echo "=================================================="

wait
