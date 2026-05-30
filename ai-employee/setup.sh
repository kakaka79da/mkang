#!/bin/bash
# ============================================================
# AI 직원 시스템 원클릭 설치 스크립트
# iMac 27" 2020 · Intel i9 · AMD Radeon Pro 5700 XT 16GB
# macOS Tahoe 26.5
# ============================================================
set -e

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
err()  { echo -e "${RED}❌ $1${RESET}"; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

echo -e "${BOLD}"
echo "=================================================="
echo "  AI 직원 시스템 설치 (Intel iMac + AMD GPU)"
echo "=================================================="
echo -e "${RESET}"

# ── Step 0: 저장 공간 확인 ──────────────────────────────────────────────────
info "Step 0: 저장 공간 확인"
AVAIL=$(df -g "$HOME" | awk 'NR==2{print $4}')
echo "  여유 공간: ${AVAIL}GB"
if [ "$AVAIL" -lt 30 ]; then
    err "저장 공간이 부족합니다 (${AVAIL}GB). 최소 30GB 이상 확보 후 재실행하세요."
fi
ok "저장 공간 충분 (${AVAIL}GB)"

# ── Step 1: Xcode Command Line Tools ────────────────────────────────────────
info "Step 1: Xcode Command Line Tools 확인"
if ! xcode-select -p &>/dev/null; then
    echo "  Xcode CLT 설치 중 (팝업창에서 '설치' 클릭)..."
    xcode-select --install
    echo "  설치 완료 후 Enter를 눌러 계속하세요..."
    read -r
else
    ok "Xcode CLT 이미 설치됨"
fi

# ── Step 2: Homebrew ─────────────────────────────────────────────────────────
info "Step 2: Homebrew 확인"
if ! command -v brew &>/dev/null; then
    echo "  Homebrew 설치 중..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/usr/local/bin/brew shellenv)"
else
    ok "Homebrew 이미 설치됨 ($(brew --version | head -1))"
fi

# ── Step 3: 의존성 설치 ───────────────────────────────────────────────────────
info "Step 3: 의존성 설치"
brew install cmake git python3 || true
ok "cmake, git, python3 준비"

# ── Step 4: llama.cpp Metal 빌드 ─────────────────────────────────────────────
info "Step 4: llama.cpp Metal 빌드 (AMD GPU 활성화)"
LLAMA_DIR="$HOME_DIR/llama.cpp"

if [ ! -d "$LLAMA_DIR" ]; then
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
else
    info "  기존 llama.cpp 업데이트 중..."
    git -C "$LLAMA_DIR" pull
fi

cd "$LLAMA_DIR"
cmake -B build \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=ON
cmake --build build --config Release -j"$(sysctl -n hw.logicalcpu)"
sudo cmake --install build
cd "$DIR"
ok "llama.cpp Metal 빌드 완료"

# GPU 확인
echo "  GPU 확인 중..."
if llama-server --version 2>&1 | grep -q "Metal\|metal"; then
    ok "Metal 백엔드 확인됨"
else
    echo "  (llama-server 실행 시 Metal 로그로 확인 가능)"
fi

# ── Step 5: Python 가상환경 ───────────────────────────────────────────────────
info "Step 5: Python 가상환경 구성"
cd "$DIR"
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q
ok "Python 패키지 설치 완료"

# ── Step 6: config.py 생성 ────────────────────────────────────────────────────
info "Step 6: 설정 파일 구성"
if [ ! -f "$DIR/config.py" ]; then
    cp "$DIR/config.example.py" "$DIR/config.py"
    # 모델 경로 자동 업데이트
    sed -i '' "s|~/ai-employee/models|$DIR/models|g" "$DIR/config.py"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  ⚙️  config.py 를 열어 아래 항목을 설정하세요:${RESET}"
    echo ""
    echo "  1. TELEGRAM_TOKEN  ← @BotFather 에서 발급"
    echo "  2. AUTHORIZED_USERS ← @userinfobot 에서 본인 ID 확인"
    echo "  3. MACHINE_ID      ← 이 컴퓨터 고유 이름"
    echo ""
    echo "  편집: open $DIR/config.py"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo "  설정 완료 후 Enter를 눌러 모델 다운로드를 계속하세요..."
    read -r
else
    ok "config.py 이미 존재"
fi

# ── Step 7: 모델 다운로드 ─────────────────────────────────────────────────────
info "Step 7: AI 모델 다운로드"
mkdir -p "$DIR/models"
pip install -q "huggingface_hub[cli]"

MODEL_PATH="$DIR/models/gpt-oss-20b-Q5_K_M.gguf"

echo ""
echo "  어떤 모델을 다운로드하시겠습니까?"
echo ""
echo "  1) GPT-OSS 20B Q5_K_M  (~13.7GB) ← 추천 ⭐ (AMD 공식 지원, o3-mini 수준)"
echo "  2) Qwen3 14B Q6_K       (~12GB)   ← 에이전트·툴콜 특화"
echo "  3) 둘 다 다운로드        (~26GB)"
echo "  4) 나중에 직접 다운로드"
echo ""
read -r -p "  선택 (1/2/3/4): " MODEL_CHOICE

case "$MODEL_CHOICE" in
    1|"")
        info "  GPT-OSS 20B 다운로드 중... (13.7GB, 10-30분 소요)"
        huggingface-cli download unsloth/gpt-oss-20b-GGUF \
            gpt-oss-20b-Q5_K_M.gguf \
            --local-dir "$DIR/models"
        # config.py 모델 경로 업데이트
        sed -i '' "s|gpt-oss-20b-Q5_K_M.gguf|$DIR/models/gpt-oss-20b-Q5_K_M.gguf|" "$DIR/config.py"
        ok "GPT-OSS 20B 다운로드 완료"
        ;;
    2)
        info "  Qwen3 14B 다운로드 중... (12GB, 10-25분 소요)"
        huggingface-cli download bartowski/Qwen_Qwen3-14B-GGUF \
            Qwen3-14B-Q6_K.gguf \
            --local-dir "$DIR/models"
        sed -i '' "s|MODEL_MAIN = .*|MODEL_MAIN = \"$DIR/models/Qwen3-14B-Q6_K.gguf\"|" "$DIR/config.py"
        ok "Qwen3 14B 다운로드 완료"
        ;;
    3)
        info "  GPT-OSS 20B 다운로드 중..."
        huggingface-cli download unsloth/gpt-oss-20b-GGUF \
            gpt-oss-20b-Q5_K_M.gguf \
            --local-dir "$DIR/models"
        info "  Qwen3 14B 다운로드 중..."
        huggingface-cli download bartowski/Qwen_Qwen3-14B-GGUF \
            Qwen3-14B-Q6_K.gguf \
            --local-dir "$DIR/models"
        ok "두 모델 다운로드 완료"
        ;;
    4)
        echo "  모델 다운로드를 건너뜁니다."
        echo "  나중에: huggingface-cli download unsloth/gpt-oss-20b-GGUF gpt-oss-20b-Q5_K_M.gguf --local-dir $DIR/models"
        ;;
esac

# ── Step 8: launchd 자동 시작 등록 ───────────────────────────────────────────
info "Step 8: 부팅 자동 시작 설정"
PLIST_SRC="$DIR/launchd/com.aiemployee.plist"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/com.aiemployee.plist"

sed "s|REPLACE_WITH_FULL_PATH|$DIR|g" "$PLIST_SRC" > "$PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
ok "부팅 자동 시작 등록 완료"

# ── 완료 ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "=================================================="
echo "  🎉 AI 직원 시스템 설치 완료!"
echo "=================================================="
echo -e "${RESET}"
echo "  시작:  $DIR/start.sh"
echo "  종료:  $DIR/stop.sh"
echo ""
echo "  LLM API:    http://localhost:11434"
echo "  Agent API:  http://localhost:8000"
echo "  로그:       $DIR/logs/"
echo ""
echo "  텔레그램에서 /start 를 보내 테스트하세요."
echo ""

read -r -p "  지금 바로 시작하시겠습니까? (y/N): " START_NOW
if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
    bash "$DIR/start.sh"
fi
