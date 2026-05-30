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
if [ ! -x "$VK_BIN" ]; then
    echo -e "${RED}❌ 빌드 실패: $VK_BIN 없음${RESET}"
    exit 1
fi

# 3. Vulkan 으로 GPU 장치 인식 확인
info "Step 3: Vulkan GPU 인식 테스트"
"$LLAMA_DIR/build-vulkan/bin/llama-bench" -m "$MODEL" -ngl 99 -n 32 -p 64 2>&1 | tail -15 || true

echo ""
ok "빌드 끝. 아래 명령으로 서버를 직접 실행해 검증하세요:"
echo ""
echo "  export VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
echo "  $VK_BIN \\"
echo "      -m $MODEL \\"
echo "      -ngl 99 -c 4096 --no-warmup --port 11434"
echo ""
echo "  그 다음 새 창에서:"
echo '  curl -s http://localhost:11434/v1/chat/completions -H "Content-Type: application/json" \'
echo '    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"/no_think 자기소개 한 문장\"}],\"max_tokens\":80}"'
echo ""
echo "  ✅ 정상 한국어 + 10 t/s 이상  → Vulkan 성공! start.sh 를 Vulkan 으로 전환"
echo "  ❌ @@@@ 또는 0.x t/s          → 이 하드웨어는 macOS GPU 불가, CPU 유지"
