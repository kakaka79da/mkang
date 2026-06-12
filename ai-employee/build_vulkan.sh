#!/bin/bash
# ============================================================
# llama.cpp Vulkan(MoltenVK) 빌드 — AMD Radeon Pro 5700 XT GPU 가속
#
# Intel iMac + AMD Radeon Pro 5700 XT:
#   Metal 백엔드 → gibberish 출력 버그 (llama.cpp #19563, 미수정)
#   Vulkan/MoltenVK → GGML_VK_VISIBLE_DEVICES=1 로 AMD 장치 지정
#   성공 시 10~75 t/s (CPU 대비 3~20배)
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }

LLAMA_DIR="$HOME/llama.cpp"
DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${1:-$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.expanduser(MODEL_MAIN))" 2>/dev/null || echo "$DIR/models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf")}"

echo "=================================================="
echo "  llama.cpp Vulkan 빌드 (AMD GPU 가속 시도)"
echo "=================================================="

# 1. Vulkan 의존성
info "Step 1: Vulkan / MoltenVK 의존성"
brew install molten-vk vulkan-loader vulkan-headers shaderc glslang vulkan-tools 2>/dev/null || true
ok "Vulkan 의존성 준비"

BREW_PREFIX="$(brew --prefix)"
VK_ICD="$BREW_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json"
if [ ! -f "$VK_ICD" ]; then
    ALT="$(find "$BREW_PREFIX" -name "MoltenVK_icd.json" 2>/dev/null | head -1)"
    [ -n "$ALT" ] && VK_ICD="$ALT"
fi
[ ! -f "$VK_ICD" ] && fail "MoltenVK ICD 없음: $VK_ICD" && exit 1
export VK_ICD_FILENAMES="$VK_ICD"
ok "ICD: $VK_ICD"

# 2. llama.cpp 최신 버전 받기
info "Step 2: llama.cpp 최신 코드 업데이트"
if [ ! -d "$LLAMA_DIR" ]; then
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
else
    git -C "$LLAMA_DIR" pull
fi
ok "llama.cpp $(git -C "$LLAMA_DIR" describe --tags --abbrev=0 2>/dev/null || git -C "$LLAMA_DIR" rev-parse --short HEAD)"

# 3. Vulkan 빌드 (Metal=OFF, CPU 빌드와 별도 폴더)
info "Step 3: Vulkan 빌드 (build-vulkan/)"
cd "$LLAMA_DIR"
cmake -B build-vulkan \
    -DGGML_METAL=OFF \
    -DGGML_VULKAN=ON \
    -DLLAMA_CURL=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64
cmake --build build-vulkan --config Release -j"$(sysctl -n hw.logicalcpu)"
ok "Vulkan 빌드 완료"

VK_BIN="$LLAMA_DIR/build-vulkan/bin/llama-server"
VK_BENCH="$LLAMA_DIR/build-vulkan/bin/llama-bench"
[ ! -x "$VK_BIN" ] && fail "빌드 실패: $VK_BIN 없음" && exit 1

# 4. Vulkan 장치 열거
info "Step 4: Vulkan GPU 장치 목록"
if command -v vulkaninfo &>/dev/null; then
    VK_ICD_FILENAMES="$VK_ICD" vulkaninfo --summary 2>/dev/null \
        | grep -E "(GPU[0-9]|deviceName|deviceType)" | head -10 || true
else
    echo "  (vulkan-tools 미설치)"
fi

# 5. 장치별 벤치마크
if [ -f "$MODEL" ] && [ -x "$VK_BENCH" ]; then
    info "Step 5: 장치별 GPU 벤치마크"
    BEST_TPS=0
    BEST_DEV=-1
    for DEV_IDX in 0 1 2; do
        echo ""
        echo "  === GGML_VK_VISIBLE_DEVICES=$DEV_IDX ==="
        RESULT=$(VK_ICD_FILENAMES="$VK_ICD" \
                 GGML_VK_VISIBLE_DEVICES="$DEV_IDX" \
                 "$VK_BENCH" -m "$MODEL" -ngl 99 -n 32 -p 64 2>&1 | tail -6)
        echo "$RESULT" | sed 's/^/    /'
        TPS=$(echo "$RESULT" | grep -oE '[0-9]+\.[0-9]+ t/s' | tail -1 | grep -oE '[0-9]+\.[0-9]+' || echo "0")
        if echo "$RESULT" | grep -qiE "vulkan|ggml_vulkan"; then
            ok "Device $DEV_IDX: Vulkan GPU 인식! ${TPS} t/s"
            if awk "BEGIN{exit !($TPS > $BEST_TPS)}"; then
                BEST_TPS="$TPS"; BEST_DEV="$DEV_IDX"
            fi
        fi
    done
    echo ""
    if [ "$BEST_DEV" -ge 0 ] 2>/dev/null; then
        ok "최적 장치: GGML_VK_VISIBLE_DEVICES=$BEST_DEV (${BEST_TPS} t/s)"
        echo ""
        echo "  start.sh 자동으로 이 설정을 사용합니다."
        echo "  현재 start.sh 에 GGML_VK_VISIBLE_DEVICES=1 설정됨."
        echo "  AMD 가 device $BEST_DEV 이면 start.sh 의 값을 수정하세요:"
        echo "    export GGML_VK_VISIBLE_DEVICES=$BEST_DEV"
    else
        echo "  ⚠️  모든 장치에서 Vulkan GPU 미인식 (BLAS/CPU 폴백)"
        echo "  → start.sh 는 자동으로 CPU 모드로 실행됩니다."
    fi
else
    echo "  (모델 파일 없어 벤치 생략)"
fi

echo ""
echo "=================================================="
ok "빌드 완료. bash start.sh 로 시스템을 기동하세요."
echo "=================================================="
