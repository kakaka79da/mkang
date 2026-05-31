#!/bin/bash
# ============================================================
# llama.cpp Vulkan(MoltenVK) 빌드 — AMD GPU GPU 가속 시도
# Intel iMac + AMD Radeon Pro 5700 XT
#
# 왜? llama.cpp Metal 백엔드는 AMD discrete GPU 에서 계산이 깨져
# (gibberish @@@@) + 0.85 t/s 로 사실상 못 쓴다 (llama.cpp #19563).
# Vulkan(MoltenVK 경유)은 같은 GPU 에서 정상 출력 + 68~75 t/s 사례가 있다.
# (llama.cpp #19563, #10879 — 5700 XT 생성 75.8 t/s 보고)
#
# 단, 일부 Intel Mac 에선 Vulkan 도 깨질 수 있다(#20104). 직접 검증 필요.
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }

LLAMA_DIR="$HOME/llama.cpp"
MODEL="${1:-$HOME/mkang/ai-employee/models/Qwen_Qwen3-8B-Q4_K_M.gguf}"

echo "=================================================="
echo "  llama.cpp Vulkan 빌드 (AMD GPU 가속 시도)"
echo "=================================================="

# 1. Vulkan 의존성 설치
info "Step 1: Vulkan / MoltenVK 의존성 설치"
brew install molten-vk vulkan-loader vulkan-headers shaderc glslang vulkan-tools 2>/dev/null || true
ok "Vulkan 의존성 준비"

# MoltenVK ICD 경로 탐지 및 환경변수 설정
BREW_PREFIX="$(brew --prefix)"
export VK_ICD_FILENAMES="$BREW_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json"
export VK_DRIVER_FILES="$VK_ICD_FILENAMES"
echo "  VK_ICD_FILENAMES=$VK_ICD_FILENAMES"

# 파일 존재 확인
if [ ! -f "$VK_ICD_FILENAMES" ]; then
    echo -e "${RED}❌ MoltenVK ICD 파일 없음: $VK_ICD_FILENAMES${RESET}"
    # 대체 경로 탐색
    ALT=$(find "$BREW_PREFIX" -name "MoltenVK_icd.json" 2>/dev/null | head -1)
    if [ -n "$ALT" ]; then
        export VK_ICD_FILENAMES="$ALT"
        echo "  대체 경로 발견: $ALT"
    fi
fi

# 2. llama.cpp Vulkan 빌드 (Metal 빌드와 별도 폴더)
info "Step 2: llama.cpp Vulkan 빌드 (build-vulkan/)"
cd "$LLAMA_DIR"
cmake -B build-vulkan \
    -DGGML_METAL=OFF \
    -DGGML_VULKAN=ON \
    -DLLAMA_CURL=ON \
    -DCMAKE_BUILD_TYPE=Release
cmake --build build-vulkan --config Release -j"$(sysctl -n hw.logicalcpu)"
ok "Vulkan 빌드 완료"

VK_BIN="$LLAMA_DIR/build-vulkan/bin/llama-server"
VK_BENCH="$LLAMA_DIR/build-vulkan/bin/llama-bench"
if [ ! -x "$VK_BIN" ]; then
    echo -e "${RED}❌ 빌드 실패: $VK_BIN 없음${RESET}"
    exit 1
fi

# 3. Vulkan GPU 장치 목록 확인
info "Step 3: Vulkan GPU 장치 열거"
if command -v vulkaninfo &>/dev/null; then
    echo "--- vulkaninfo --summary ---"
    VK_ICD_FILENAMES="$VK_ICD_FILENAMES" vulkaninfo --summary 2>/dev/null | grep -E "(GPU|deviceName|deviceType|driverVersion)" || true
    echo "---"
else
    echo "  (vulkan-tools 미설치 — brew install vulkan-tools)"
fi

# 4. GPU 장치별 벤치마크 (AMD 5700 XT 는 보통 device 1)
info "Step 4: GPU 장치별 성능 측정"
if [ -f "$MODEL" ]; then
    for DEV_IDX in 0 1 2; do
        echo ""
        echo "  === Device $DEV_IDX 테스트 ==="
        VK_ICD_FILENAMES="$VK_ICD_FILENAMES" \
        GGML_VK_VISIBLE_DEVICES="$DEV_IDX" \
        "$VK_BENCH" -m "$MODEL" -ngl 99 -n 32 -p 64 2>&1 | tail -8 || true
    done
else
    echo "  모델 파일 없음 — 벤치 생략: $MODEL"
fi

echo ""
ok "빌드 끝. 벤치 결과에서 backend=Vulkan + t/s 확인하세요."
echo ""
echo "  ✅ backend=Vulkan + 10 t/s 이상 → GPU 성공! run_vulkan.sh 사용"
echo "  ❌ backend=BLAS (CPU) 또는 @@@@  → test_gpu.sh 로 추가 진단"
echo ""
echo "  Vulkan 서버 직접 실행:"
echo "    export VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
echo "    $VK_BIN -m $MODEL -ngl 99 -c 4096 --no-warmup --port 11434"
