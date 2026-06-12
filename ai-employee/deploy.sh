#!/bin/bash
# ============================================================
# 올인원 배포 스크립트 — 이것 하나만 실행하면 끝
#
#   cd ~/mkang && git pull origin claude/compassionate-sagan-2QGA4 \
#     && bash ai-employee/deploy.sh
#
# 하는 일 (모두 자동, 이미 된 것은 건너뜀):
#   1. Python 패키지 설치/업데이트
#   2. 모델 확인 — 없으면 디스크 용량에 맞춰 자동 다운로드
#   3. Vulkan GPU 빌드 (실패해도 계속 진행, CPU 폴백)
#   4. 부팅 자동 시작 등록 (launchd)
#   5. 시스템 기동 + 동작 확인
#
# GPU 빌드 건너뛰기: SKIP_GPU=1 bash ai-employee/deploy.sh
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BOLD="\033[1m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo -e "${BOLD}"
echo "============================================================"
echo "  AI 직원 시스템 — 올인원 배포"
echo "============================================================"
echo -e "${RESET}"

# ── 1. Python 환경 ───────────────────────────────────────────────────────────
info "[1/5] Python 패키지 설치"
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q
ok "패키지 준비 완료"

# config.py 확인
if [ ! -f "config.py" ]; then
    cp config.example.py config.py
    warn "config.py 를 새로 만들었습니다. TELEGRAM_TOKEN 과 AUTHORIZED_USERS 를 채워야 봇이 작동합니다!"
    echo "   편집: open $DIR/config.py"
fi

# ── 2. 모델 확인/다운로드 ─────────────────────────────────────────────────────
info "[2/5] AI 모델 확인"
mkdir -p models

MODEL=$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.expanduser(MODEL_MAIN))" 2>/dev/null || echo "")
AVAIL=$(df -g "$HOME" | awk 'NR==2{print $4}')

# 이미 받아둔 모델 중 가장 좋은 것 탐색
BEST_LOCAL=""
for f in "models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf" \
         "models/Qwen3-30B-A3B-Instruct-2507-Q3_K_M.gguf" \
         "models/Qwen_Qwen3-8B-Q4_K_M.gguf"; do
    if [ -f "$f" ]; then BEST_LOCAL="$DIR/$f"; break; fi
done

if [ -n "$BEST_LOCAL" ]; then
    MODEL="$BEST_LOCAL"
    ok "기존 모델 사용: $(basename "$MODEL")"
elif [ "$AVAIL" -ge 16 ]; then
    # HF CLI 준비
    if command -v hf &>/dev/null; then HF_CMD="hf";
    elif command -v huggingface-cli &>/dev/null; then HF_CMD="huggingface-cli";
    else pip install -q "huggingface_hub[cli]"; HF_CMD="hf"; command -v hf &>/dev/null || HF_CMD="huggingface-cli"; fi

    if [ "$AVAIL" -ge 20 ]; then
        FILE="Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
    else
        FILE="Qwen3-30B-A3B-Instruct-2507-Q3_K_M.gguf"
    fi
    info "모델 다운로드: $FILE (30분~1시간, 디스크 ${AVAIL}GB 여유)"
    "$HF_CMD" download unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF "$FILE" --local-dir models
    MODEL="$DIR/models/$FILE"
    ok "다운로드 완료"
else
    fail "디스크 여유 부족(${AVAIL}GB)이고 기존 모델도 없습니다. 공간 확보 후 재실행하세요."
    exit 1
fi

# config.py 모델 경로 동기화
sed -i '' "s|^MODEL_MAIN = .*|MODEL_MAIN = \"$MODEL\"|" config.py
ok "모델 설정: $(basename "$MODEL")"

# ── 3. Vulkan GPU 빌드 (best-effort) ─────────────────────────────────────────
info "[3/5] Vulkan GPU 빌드 (AMD Radeon Pro 5700 XT)"
VK_BIN="$HOME/llama.cpp/build-vulkan/bin/llama-server"
if [ "${SKIP_GPU:-0}" = "1" ]; then
    warn "SKIP_GPU=1 — GPU 빌드 건너뜀"
elif [ -x "$VK_BIN" ]; then
    ok "Vulkan 바이너리 이미 존재 — 빌드 건너뜀"
else
    echo "  (10~20분 소요. 실패해도 CPU 모드로 계속 작동합니다)"
    if bash build_vulkan.sh "$MODEL"; then
        ok "Vulkan 빌드 성공"
    else
        warn "Vulkan 빌드 실패 — CPU 모드로 진행 (성능에는 문제없음)"
    fi
fi

# CPU 빌드도 없으면 llama.cpp Metal 빌드 (CPU 실행용)
CPU_BIN="$HOME/llama.cpp/build/bin/llama-server"
if [ ! -x "$CPU_BIN" ] && ! command -v llama-server &>/dev/null; then
    info "llama.cpp CPU 빌드 (필수, 10~20분)"
    brew install cmake git 2>/dev/null || true
    if [ ! -d "$HOME/llama.cpp" ]; then
        git clone https://github.com/ggml-org/llama.cpp "$HOME/llama.cpp"
    fi
    cd "$HOME/llama.cpp"
    cmake -B build -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON
    cmake --build build --config Release -j"$(sysctl -n hw.logicalcpu)"
    cd "$DIR"
    ok "llama.cpp 빌드 완료"
fi

# ── 4. 부팅 자동 시작 등록 ───────────────────────────────────────────────────
info "[4/5] 부팅 자동 시작 등록 (launchd)"
bash install_autostart.sh install
ok "재부팅해도 자동으로 켜집니다"

# ── 5. 시스템 기동 ───────────────────────────────────────────────────────────
info "[5/5] 시스템 기동"
# launchd 가 KeepAlive 로 관리하도록 launchd 경유로 시작
launchctl kickstart -k "gui/$(id -u)/com.aiemployee" 2>/dev/null || {
    # launchctl kickstart 미지원(구버전 macOS) 시 직접 실행
    bash stop.sh 2>/dev/null || true
    nohup bash start.sh > logs/deploy_start.log 2>&1 &
}

# 동작 확인 (최대 2분 대기 — 30B 모델 로딩은 시간이 걸림)
echo "  LLM 서버 기동 대기 중 (모델 로딩, 최대 2분)..."
READY=0
for i in $(seq 1 60); do
    if curl -s http://localhost:11434/health > /dev/null 2>&1; then
        READY=1; break
    fi
    printf "."
    sleep 2
done
echo ""

echo ""
echo "============================================================"
if [ "$READY" = "1" ]; then
    ok "배포 완료! 시스템 가동 중"
    # GPU 모드 확인
    if grep -qiE "ggml_vulkan" logs/llm.log 2>/dev/null; then
        echo "  GPU: ✅ Vulkan (AMD Radeon Pro 5700 XT)"
    else
        echo "  GPU: CPU 모드 (i9 10코어)"
    fi
    echo "  모델: $(basename "$MODEL")"
    echo ""
    echo "  📱 지금 텔레그램(@MImac_bot)에 메시지를 보내보세요!"
else
    warn "서버가 아직 준비되지 않았습니다 (대형 모델은 로딩에 더 걸릴 수 있음)"
    echo "  확인: tail -f $DIR/logs/llm.log"
    echo "  텔레그램 봇 로그: tail -f $DIR/logs/telegram.log"
fi
echo "============================================================"
