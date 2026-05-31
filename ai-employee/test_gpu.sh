#!/bin/bash
# ============================================================
# GPU 진단 스크립트 — Intel iMac + AMD Radeon Pro 5700 XT
#
# 실행: bash test_gpu.sh [model_path]
# 출력: 각 백엔드/장치 조합의 t/s 와 합격/불합격 판정
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }
info() { echo -e "${CYAN}▶  $1${RESET}"; }

LLAMA_DIR="$HOME/llama.cpp"
MODEL="${1:-$HOME/mkang/ai-employee/models/Qwen_Qwen3-8B-Q4_K_M.gguf}"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /usr/local)"
VK_ICD="$BREW_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json"

echo "============================================================"
echo "  GPU 진단 — Intel iMac + AMD Radeon Pro 5700 XT"
echo "  모델: $MODEL"
echo "============================================================"
echo ""

# ── 환경 확인 ───────────────────────────────────────────────────────────────
info "환경 확인"
echo "  macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
echo "  CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
echo "  GPU: $(system_profiler SPDisplaysDataType 2>/dev/null | grep 'Chipset Model' | head -2 | tr '\n' ' ' || echo unknown)"
echo ""

# ── MoltenVK 설치 확인 ─────────────────────────────────────────────────────
info "MoltenVK 확인"
if [ -f "$VK_ICD" ]; then
    ok "ICD 파일 발견: $VK_ICD"
else
    # 대체 경로 탐색
    ALT=$(find "$BREW_PREFIX" -name "MoltenVK_icd.json" 2>/dev/null | head -1)
    if [ -n "$ALT" ]; then
        VK_ICD="$ALT"
        warn "대체 경로 사용: $VK_ICD"
    else
        fail "MoltenVK ICD 없음 — brew install molten-vk 실행"
        VK_ICD=""
    fi
fi

# ── Vulkan 장치 열거 ────────────────────────────────────────────────────────
info "Vulkan 물리 장치 목록"
if command -v vulkaninfo &>/dev/null && [ -n "$VK_ICD" ]; then
    echo ""
    VK_ICD_FILENAMES="$VK_ICD" vulkaninfo --summary 2>/dev/null \
        | grep -A2 "GPU" | grep -E "(GPU[0-9]|deviceName|deviceType)" \
        | sed 's/^/  /' || echo "  (vulkaninfo 출력 없음)"
    echo ""
else
    warn "vulkaninfo 없음 — brew install vulkan-tools"
fi

# ── 바이너리 탐색 ──────────────────────────────────────────────────────────
CPU_BIN=""
VK_BIN=""
if [ -x "$LLAMA_DIR/build/bin/llama-bench" ]; then
    CPU_BIN="$LLAMA_DIR/build/bin/llama-bench"
fi
if [ -x "$LLAMA_DIR/build-vulkan/bin/llama-bench" ]; then
    VK_BIN="$LLAMA_DIR/build-vulkan/bin/llama-bench"
fi

echo "  Metal/CPU 벤치: ${CPU_BIN:-없음}"
echo "  Vulkan 벤치:    ${VK_BIN:-없음 (build_vulkan.sh 실행 필요)}"
echo ""

if [ ! -f "$MODEL" ]; then
    fail "모델 파일 없음: $MODEL"
    echo "  setup.sh 를 실행해 모델을 다운로드하세요."
    exit 1
fi

# ── 기준선: CPU 테스트 ───────────────────────────────────────────────────────
if [ -n "$CPU_BIN" ]; then
    info "CPU 기준선 측정 (10초)"
    CPU_RESULT=$(GGML_NO_METAL=1 "$CPU_BIN" -m "$MODEL" -ngl 0 -n 32 -p 64 2>&1 | tail -5)
    echo "$CPU_RESULT" | sed 's/^/  /'
    CPU_TPS=$(echo "$CPU_RESULT" | grep -oE '[0-9]+\.[0-9]+ t/s' | tail -1 | grep -oE '[0-9]+\.[0-9]+' || echo "?")
    ok "CPU 기준: ${CPU_TPS} t/s"
    echo ""
fi

# ── Vulkan 테스트: 장치 0, 1, 2 ─────────────────────────────────────────────
if [ -n "$VK_BIN" ] && [ -n "$VK_ICD" ]; then
    export VK_ICD_FILENAMES="$VK_ICD"

    BEST_TPS=0
    BEST_DEV=-1

    for DEV_IDX in 0 1 2; do
        info "Vulkan Device $DEV_IDX 테스트"
        # GGML_VK_VISIBLE_DEVICES: 보이는 장치 인덱스 필터링 (AMD = 1 이면 "1" 로 설정)
        VK_RESULT=$(GGML_VK_VISIBLE_DEVICES="$DEV_IDX" \
            "$VK_BIN" -m "$MODEL" -ngl 99 -n 32 -p 64 2>&1 | tail -8)
        echo "$VK_RESULT" | sed 's/^/  /'

        BACKEND=$(echo "$VK_RESULT" | grep -oiE 'backend[[:space:]]*=[[:space:]]*[A-Za-z]+' | head -1 || echo "")
        TPS=$(echo "$VK_RESULT" | grep -oE '[0-9]+\.[0-9]+ t/s' | tail -1 | grep -oE '[0-9]+\.[0-9]+' || echo "0")

        if echo "$BACKEND" | grep -qi "vulkan"; then
            ok "Device $DEV_IDX: Vulkan GPU 인식! ${TPS} t/s"
            if awk "BEGIN{exit !($TPS > $BEST_TPS)}"; then
                BEST_TPS="$TPS"
                BEST_DEV="$DEV_IDX"
            fi
        elif echo "$VK_RESULT" | grep -qi "BLAS"; then
            warn "Device $DEV_IDX: CPU(BLAS) 폴백 — GPU 미인식"
        else
            warn "Device $DEV_IDX: 결과 불명확"
        fi
        echo ""
    done

    # ── 결론 ────────────────────────────────────────────────────────────────
    echo "============================================================"
    if [ "$BEST_DEV" -ge 0 ] 2>/dev/null; then
        ok "결론: Device $BEST_DEV 에서 Vulkan GPU 작동 확인 (${BEST_TPS} t/s)"
        echo ""
        echo "  run_vulkan.sh 를 사용하거나 아래 명령으로 서버를 시작하세요:"
        echo ""
        echo "    export VK_ICD_FILENAMES=$VK_ICD"
        echo "    export GGML_VK_VISIBLE_DEVICES=$BEST_DEV"
        echo "    $LLAMA_DIR/build-vulkan/bin/llama-server \\"
        echo "        -m $MODEL \\"
        echo "        -ngl 99 -c 4096 --no-warmup --port 11434"
        echo ""
        echo "  start.sh 를 Vulkan 모드로 전환하려면:"
        echo "    bash run_vulkan.sh"
    else
        fail "결론: 모든 장치에서 Vulkan GPU 미인식"
        echo ""
        echo "  원인 후보:"
        echo "  1. MoltenVK 가 이 하드웨어의 AMD GPU 를 지원하지 않음 (Issue #20104)"
        echo "  2. VK_ICD_FILENAMES 경로 오류"
        echo "  3. macOS 버전 호환성 문제"
        echo ""
        echo "  → CPU 모드(start.sh)가 현재 최선입니다."
        echo "     Intel i9-10900K CPU: ~3.7 t/s (정상 출력, 안정적)"
    fi
else
    warn "Vulkan 바이너리 없음 — build_vulkan.sh 를 먼저 실행하세요."
fi
