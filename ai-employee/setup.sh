#!/bin/bash
# ============================================================
# AI 직원 시스템 원클릭 설치 스크립트
# iMac 2020 · Intel i9 · AMD Radeon Pro 5700 XT 16GB · macOS
# ============================================================
set -e

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
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

# ── Step 0: 저장 공간 확인 ───────────────────────────────────────────────────
info "Step 0: 저장 공간 확인"
AVAIL=$(df -g "$HOME" | awk 'NR==2{print $4}')
echo "  여유 공간: ${AVAIL}GB"
if [ "$AVAIL" -lt 8 ]; then
    err "저장 공간이 너무 부족합니다 (${AVAIL}GB). 최소 8GB 필요."
fi
ok "저장 공간 확인 완료 (${AVAIL}GB)"

# ── Step 1: Xcode Command Line Tools ─────────────────────────────────────────
info "Step 1: Xcode Command Line Tools 확인"
if ! xcode-select -p &>/dev/null; then
    echo "  Xcode CLT 설치 중 (팝업창에서 '설치' 클릭)..."
    xcode-select --install
    echo "  설치 완료 후 Enter를 눌러 계속하세요..."
    read -r
else
    ok "Xcode CLT 이미 설치됨"
fi

# ── Step 2: Homebrew ──────────────────────────────────────────────────────────
info "Step 2: Homebrew 확인"
if ! command -v brew &>/dev/null; then
    echo "  Homebrew 설치 중..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/usr/local/bin/brew shellenv)"
else
    ok "Homebrew 이미 설치됨 ($(brew --version | head -1))"
fi

# ── Step 3: 의존성 설치 ──────────────────────────────────────────────────────
info "Step 3: 의존성 설치"
brew install cmake git python3 || true
ok "cmake, git, python3 준비"

# ── Step 4: llama.cpp 빌드 ───────────────────────────────────────────────────
info "Step 4: llama.cpp 빌드"
# Intel Mac + AMD Radeon Pro 5700 XT: Metal 백엔드는 gibberish + 0.8 t/s 버그.
# CPU 모드가 GPU 보다 25배 빠르다. Metal=ON 으로 빌드하되 -ngl 0 으로 실행.
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
# sudo cmake --install 은 rpath 누락 버그가 있어 건너뜀.
# start.sh 에서 build/bin/llama-server 를 직접 사용한다.
cd "$DIR"
ok "llama.cpp 빌드 완료 ($LLAMA_DIR/build/bin/llama-server)"

# ── Step 5: Python 가상환경 ──────────────────────────────────────────────────
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
    sed -i '' "s|~/mkang/ai-employee/models|$DIR/models|g" "$DIR/config.py"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  ⚙️  config.py 를 열어 아래 항목을 설정하세요:${RESET}"
    echo ""
    echo "  1. TELEGRAM_TOKEN  ← @BotFather 에서 발급"
    echo "  2. AUTHORIZED_USERS ← @userinfobot 에서 본인 ID 확인"
    echo "  3. MACHINE_ID      ← 이 컴퓨터 고유 이름 (예: iMac-Node-1)"
    echo ""
    echo "  편집: open $DIR/config.py"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo "  설정 완료 후 Enter를 눌러 모델 다운로드를 계속하세요..."
    read -r
else
    ok "config.py 이미 존재"
fi

# ── Step 7: 모델 다운로드 (디스크 용량에 따라 자동 선택) ──────────────────────
info "Step 7: AI 모델 다운로드"
mkdir -p "$DIR/models"

# HuggingFace CLI 명령어 탐지 (hf 가 신규, huggingface-cli 는 구버전)
if command -v hf &>/dev/null; then
    HF_CMD="hf"
elif command -v huggingface-cli &>/dev/null; then
    HF_CMD="huggingface-cli"
else
    pip install -q "huggingface_hub[cli]"
    if command -v hf &>/dev/null; then HF_CMD="hf"; else HF_CMD="huggingface-cli"; fi
fi
echo "  HF 명령어: $HF_CMD"

# 용량 기준 자동 모델 선택
if [ "$AVAIL" -ge 20 ]; then
    REPO="unsloth/gpt-oss-20b-GGUF"
    FILE="gpt-oss-20b-Q5_K_M.gguf"
    echo "  → 20GB 이상: GPT-OSS 20B Q5_K_M 선택 (~13.7GB, o3-mini 수준)"
elif [ "$AVAIL" -ge 14 ]; then
    REPO="bartowski/Qwen_Qwen3-14B-GGUF"
    FILE="Qwen_Qwen3-14B-Q4_K_M.gguf"
    echo "  → 14GB 이상: Qwen3 14B Q4_K_M 선택 (~8.4GB)"
else
    REPO="bartowski/Qwen_Qwen3-8B-GGUF"
    FILE="Qwen_Qwen3-8B-Q4_K_M.gguf"
    echo "  → 14GB 미만: Qwen3 8B Q4_K_M 선택 (~5GB)"
fi

MODEL_PATH="$DIR/models/$FILE"
if [ -f "$MODEL_PATH" ]; then
    ok "모델 이미 존재: $MODEL_PATH"
else
    echo "  다운로드 중: $REPO / $FILE"
    "$HF_CMD" download "$REPO" "$FILE" --local-dir "$DIR/models"
    ok "모델 다운로드 완료: $MODEL_PATH"
fi

# config.py 모델 경로 업데이트
sed -i '' "s|MODEL_MAIN = .*|MODEL_MAIN = \"$MODEL_PATH\"|" "$DIR/config.py"
ok "config.py 모델 경로 업데이트: $MODEL_PATH"

# ── Step 8: launchd 자동 시작 등록 ───────────────────────────────────────────
info "Step 8: 부팅 자동 시작 설정"
PLIST_SRC="$DIR/launchd/com.aiemployee.plist"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/com.aiemployee.plist"

if [ -f "$PLIST_SRC" ]; then
    sed "s|REPLACE_WITH_FULL_PATH|$DIR|g" "$PLIST_SRC" > "$PLIST_DST"
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    launchctl load "$PLIST_DST"
    ok "부팅 자동 시작 등록 완료"
else
    echo "  (launchd plist 없음 — 건너뜀)"
fi

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "=================================================="
echo "  AI 직원 시스템 설치 완료!"
echo "=================================================="
echo -e "${RESET}"
echo "  시작:  bash $DIR/start.sh"
echo "  종료:  bash $DIR/stop.sh"
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
