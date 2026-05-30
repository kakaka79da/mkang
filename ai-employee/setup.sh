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

# ── Step 0: 저장 공간 확인 및 자동 정리 ────────────────────────────────────
info "Step 0: 저장 공간 확인 및 자동 정리"
AVAIL=$(df -g "$HOME" | awk 'NR==2{print $4}')
echo "  현재 여유 공간: ${AVAIL}GB"

if [ "$AVAIL" -lt 14 ]; then
    info "  자동 정리 시작..."
    brew cleanup --prune=all 2>/dev/null || true
    rm -rf ~/Library/Caches/pip 2>/dev/null || true
    rm -rf ~/Library/Caches/com.apple.dt.Xcode 2>/dev/null || true
    rm -rf ~/Library/Developer/Xcode/DerivedData 2>/dev/null || true
    AVAIL=$(df -g "$HOME" | awk 'NR==2{print $4}')
    echo "  정리 후 여유 공간: ${AVAIL}GB"
fi

if [ "$AVAIL" -lt 7 ]; then
    echo ""
    echo "  ⚠️  여유 공간 부족 (${AVAIL}GB). 아래에서 큰 파일을 확인하세요:"
    du -sh ~/Downloads/* 2>/dev/null | sort -hr | head -10 | sed 's/^/     /'
    err "저장 공간 부족 (${AVAIL}GB / 최소 7GB 필요)"
fi

# 공간에 따라 자동으로 최적 모델 선택
if   [ "$AVAIL" -ge 20 ]; then AUTO_MODEL="large"   # GPT-OSS 20B  ~13.7GB
elif [ "$AVAIL" -ge 14 ]; then AUTO_MODEL="medium"  # Qwen3 14B    ~9GB
else                            AUTO_MODEL="small"   # Qwen3 8B     ~5GB
fi
ok "저장 공간 확인 완료 (${AVAIL}GB 여유 → ${AUTO_MODEL} 모델 선택)"

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

# huggingface 다운로드 명령어 감지 (hf 또는 huggingface-cli)
pip install -q "huggingface_hub" 2>/dev/null || true
if command -v hf &>/dev/null; then
    HF_DL="hf download"
elif command -v huggingface-cli &>/dev/null; then
    HF_DL="huggingface-cli download"
else
    pip install -q "huggingface_hub[cli]" 2>/dev/null || pip install -q huggingface_hub
    HF_DL="hf download"
fi
echo "  다운로드 명령어: $HF_DL"

echo ""
case "$AUTO_MODEL" in
    small)
        echo "  ℹ️  여유 공간 ${AVAIL}GB → Qwen3 8B Q4_K_M (~5GB) 자동 선택"
        info "  Qwen3 8B 다운로드 중... (5GB, 5-10분 소요)"
        $HF_DL bartowski/Qwen_Qwen3-8B-GGUF \
            Qwen_Qwen3-8B-Q4_K_M.gguf \
            --local-dir "$DIR/models"
        MODEL_FILE="$DIR/models/Qwen_Qwen3-8B-Q4_K_M.gguf"
        ok "Qwen3 8B Q4_K_M 다운로드 완료 (나중에 공간 확보 후 더 큰 모델로 교체 가능)"
        ;;
    medium)
        echo "  ℹ️  여유 공간 ${AVAIL}GB → Qwen3 14B Q4_K_M (~9GB) 자동 선택"
        info "  Qwen3 14B 다운로드 중... (9GB, 10-20분 소요)"
        $HF_DL bartowski/Qwen_Qwen3-14B-GGUF \
            Qwen3-14B-Q4_K_M.gguf \
            --local-dir "$DIR/models"
        MODEL_FILE="$DIR/models/Qwen3-14B-Q4_K_M.gguf"
        ok "Qwen3 14B Q4_K_M 다운로드 완료"
        ;;
    large)
        echo "  ℹ️  여유 공간 ${AVAIL}GB → GPT-OSS 20B Q5_K_M (~13.7GB) 자동 선택"
        info "  GPT-OSS 20B 다운로드 중... (13.7GB, 15-30분 소요)"
        $HF_DL unsloth/gpt-oss-20b-GGUF \
            gpt-oss-20b-Q5_K_M.gguf \
            --local-dir "$DIR/models"
        MODEL_FILE="$DIR/models/gpt-oss-20b-Q5_K_M.gguf"
        ok "GPT-OSS 20B 다운로드 완료"
        ;;
esac
sed -i '' "s|MODEL_MAIN = .*|MODEL_MAIN = \"$MODEL_FILE\"|" "$DIR/config.py"

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
