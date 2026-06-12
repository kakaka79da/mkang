#!/bin/bash
# ============================================================
# Linux ROCm + llama.cpp GPU 설치
# AMD Radeon Pro 5700 XT (GFX1010 / Navi 10 / RDNA1)
#
# 사용법: Ubuntu 24.04 에서 실행
#   bash linux_gpu_setup.sh
#
# 예상 속도: Qwen3-30B-A3B Q4_K_M @ 50~80 t/s (macOS CPU 대비 5~8배)
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; exit 1; }

# Ubuntu인지 확인
if ! command -v apt &>/dev/null; then
    fail "이 스크립트는 Ubuntu (apt) 전용입니다."
fi

UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
echo "======================================================="
echo "  ROCm + llama.cpp GPU 설치 — Ubuntu $UBUNTU_VER"
echo "  GPU: AMD Radeon Pro 5700 XT (GFX1010)"
echo "======================================================="

# ── 1. ROCm 설치 ─────────────────────────────────────────────
info "[1/4] ROCm 6.x 설치"
sudo apt-get update -q
sudo apt-get install -y wget gnupg2

# ROCm 공식 저장소 추가
wget -q -O /tmp/rocm.gpg https://repo.radeon.com/rocm/rocm.gpg.key
sudo gpg --dearmor -o /usr/share/keyrings/rocm-archive-keyring.gpg /tmp/rocm.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm-archive-keyring.gpg] \
    https://repo.radeon.com/rocm/apt/latest noble main" \
    | sudo tee /etc/apt/sources.list.d/rocm.list
sudo apt-get update -q

sudo apt-get install -y rocm-hip-sdk rocm-dev
ok "ROCm 설치 완료"

# GPU 접근 권한
sudo usermod -aG render,video "$USER"
echo 'export PATH=$PATH:/opt/rocm/bin' >> ~/.bashrc
echo 'export HSA_OVERRIDE_GFX_VERSION=10.1.0' >> ~/.bashrc  # GFX1010 강제 지정
source ~/.bashrc || true

# ── 2. llama.cpp ROCm 빌드 ────────────────────────────────────
info "[2/4] llama.cpp ROCm(HIP) 빌드"
sudo apt-get install -y cmake git build-essential

LLAMA_DIR="$HOME/llama.cpp"
if [ ! -d "$LLAMA_DIR" ]; then
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
else
    git -C "$LLAMA_DIR" pull
fi

cd "$LLAMA_DIR"
# HSA_OVERRIDE_GFX_VERSION: 5700 XT(GFX1010)을 ROCm이 공식 지원 목록에서 제외한 경우 우회
export HSA_OVERRIDE_GFX_VERSION=10.1.0
cmake -B build-rocm \
    -DGGML_HIPBLAS=ON \
    -DAMDGPU_TARGETS=gfx1010 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=ON
cmake --build build-rocm --config Release -j"$(nproc)"
ok "ROCm 빌드 완료"

# ── 3. 모델 확인/다운로드 ─────────────────────────────────────
info "[3/4] 모델 확인"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/models"
mkdir -p "$MODEL_DIR"

# macOS에서 이미 다운받은 모델을 사용 (같은 models/ 폴더 공유 시)
BEST_MODEL=""
for f in "$MODEL_DIR/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf" \
          "$MODEL_DIR/Qwen3-30B-A3B-Instruct-2507-Q3_K_M.gguf"; do
    if [ -f "$f" ]; then BEST_MODEL="$f"; break; fi
done

if [ -z "$BEST_MODEL" ]; then
    info "모델 다운로드 (Qwen3-30B-A3B Q4_K_M, ~18.6GB)"
    pip3 install -q "huggingface_hub[cli]"
    huggingface-cli download unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF \
        Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf --local-dir "$MODEL_DIR"
    BEST_MODEL="$MODEL_DIR/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
fi
ok "모델: $(basename "$BEST_MODEL")"

# ── 4. 벤치마크 테스트 ────────────────────────────────────────
info "[4/4] GPU 추론 테스트"
VK_BIN="$LLAMA_DIR/build-rocm/bin/llama-server"
BENCH_BIN="$LLAMA_DIR/build-rocm/bin/llama-bench"

HSA_OVERRIDE_GFX_VERSION=10.1.0 "$BENCH_BIN" \
    -m "$BEST_MODEL" -ngl 99 -n 32 -p 64 2>&1 | tail -5

echo ""
echo "======================================================="
ok "ROCm 설치 완료!"
echo "  모델: $(basename "$BEST_MODEL")"
echo "  서버: HSA_OVERRIDE_GFX_VERSION=10.1.0 $VK_BIN -m $BEST_MODEL -ngl 99 --port 11434"
echo ""
echo "  start.sh 에서 자동으로 ROCm 모드를 사용하려면:"
echo "    echo 'GPU_OK=1' > $SCRIPT_DIR/gpu.env"
echo "    echo 'VK_DEVICE=\"\"' >> $SCRIPT_DIR/gpu.env"
echo "    bash $SCRIPT_DIR/start.sh"
echo ""
echo "  재부팅 후에도 사용하려면:"
echo "    bash $SCRIPT_DIR/install_autostart.sh install"
echo "======================================================="
