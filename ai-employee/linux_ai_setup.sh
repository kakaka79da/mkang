#!/bin/bash
# ============================================================
# 듀얼 부팅 2단계 — Ubuntu 에서 실행하는 올인원 설치
#
#   git clone https://github.com/kakaka79da/mkang ~/mkang
#   bash ~/mkang/ai-employee/linux_ai_setup.sh
#
# 하는 일 (모두 자동):
#   1. ROCm 설치 — AMD Radeon Pro 5700 XT GPU 가속 (드디어!)
#   2. llama.cpp HIP(ROCm) 빌드
#   3. Python 환경 + AI 직원 시스템 설치
#   4. config.py / 모델 — macOS 파티션에서 복사 시도, 안 되면 입력/다운로드
#   5. systemd 등록 → 부팅하면 자동 시작
#
# 예상 속도: Qwen3-30B-A3B Q4_K_M @ 50~80 t/s (macOS CPU 의 5배+)
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BOLD="\033[1m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
LLAMA_DIR="$HOME/llama.cpp"
export HSA_OVERRIDE_GFX_VERSION=10.1.0   # 5700 XT(GFX1010) ROCm 인식용

command -v apt >/dev/null || { fail "Ubuntu(apt) 전용 스크립트입니다."; exit 1; }

echo -e "${BOLD}"
echo "============================================================"
echo "  AI 직원 시스템 — Ubuntu + ROCm GPU 올인원 설치"
echo "============================================================"
echo -e "${RESET}"

# ── 1. ROCm 설치 ─────────────────────────────────────────────
info "[1/5] ROCm 설치 (AMD GPU 드라이버/컴파일러)"
if command -v hipcc >/dev/null 2>&1; then
    ok "ROCm 이미 설치됨 — 건너뜀"
else
    sudo apt-get update -q
    sudo apt-get install -y wget gnupg2 curl git build-essential cmake \
        python3-venv python3-pip libcurl4-openssl-dev
    wget -q -O /tmp/rocm.gpg https://repo.radeon.com/rocm/rocm.gpg.key
    sudo gpg --yes --dearmor -o /usr/share/keyrings/rocm-archive-keyring.gpg /tmp/rocm.gpg
    CODENAME=$(lsb_release -cs)
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm-archive-keyring.gpg] https://repo.radeon.com/rocm/apt/latest $CODENAME main" \
        | sudo tee /etc/apt/sources.list.d/rocm.list >/dev/null
    sudo apt-get update -q
    sudo apt-get install -y rocm-hip-sdk rocminfo
    sudo usermod -aG render,video "$USER"
    grep -q HSA_OVERRIDE_GFX_VERSION ~/.bashrc || {
        echo 'export PATH=$PATH:/opt/rocm/bin' >> ~/.bashrc
        echo 'export HSA_OVERRIDE_GFX_VERSION=10.1.0' >> ~/.bashrc
    }
    ok "ROCm 설치 완료"
fi

# GPU 인식 확인
if /opt/rocm/bin/rocminfo 2>/dev/null | grep -qi "gfx101"; then
    ok "GPU 인식됨: $(/opt/rocm/bin/rocminfo | grep -m1 'Marketing Name' | sed 's/.*: *//')"
else
    warn "rocminfo 에서 GPU 미확인 — 그룹 권한 반영을 위해 재부팅 후 이 스크립트를 다시 실행하면 됩니다."
fi

# ── 2. llama.cpp ROCm 빌드 ───────────────────────────────────
info "[2/5] llama.cpp HIP(ROCm) 빌드"
ROCM_BIN="$LLAMA_DIR/build-rocm/bin/llama-server"
if [ -x "$ROCM_BIN" ]; then
    ok "이미 빌드됨 — 건너뜀"
else
    if [ ! -d "$LLAMA_DIR" ]; then
        git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
    fi
    cd "$LLAMA_DIR"
    HIPCXX=/opt/rocm/llvm/bin/clang++ cmake -B build-rocm \
        -DGGML_HIP=ON \
        -DAMDGPU_TARGETS=gfx1010 \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_CURL=ON
    cmake --build build-rocm --config Release -j"$(nproc)"
    cd "$DIR"
    [ -x "$ROCM_BIN" ] || { fail "빌드 실패"; exit 1; }
    ok "ROCm 빌드 완료"
fi

# ── 3. Python 환경 ───────────────────────────────────────────
info "[3/5] Python 환경 + 패키지"
if [ ! -d venv ]; then python3 -m venv venv; fi
source venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
ok "패키지 준비 완료"

# ── 4. config.py / 모델 — macOS 파티션에서 복사 시도 ──────────
info "[4/5] 설정과 모델 가져오기"

MNT=/mnt/macos
copy_from_macos() {
    # t2linux 커널은 APFS 읽기 모듈(apfs)을 포함 — 읽기 전용 마운트 시도
    local APFS_PART
    APFS_PART=$(lsblk -rno NAME,FSTYPE | awk '$2=="apfs"{print "/dev/"$1; exit}')
    [ -z "$APFS_PART" ] && return 1
    sudo mkdir -p "$MNT"
    sudo mount -t apfs -o ro "$APFS_PART" "$MNT" 2>/dev/null || return 1
    local SRC
    SRC=$(find "$MNT" -maxdepth 4 -type d -path "*/mkang/ai-employee" 2>/dev/null | head -1)
    [ -z "$SRC" ] && { sudo umount "$MNT"; return 1; }
    [ ! -f config.py ] && [ -f "$SRC/config.py" ] && cp "$SRC/config.py" config.py
    mkdir -p models
    for f in "$SRC"/models/*.gguf; do
        [ -f "$f" ] || continue
        [ -f "models/$(basename "$f")" ] || { echo "  모델 복사 중: $(basename "$f")"; cp "$f" models/; }
    done
    # Google Drive 인증 파일도 있으면 복사
    for f in credentials.json token.json; do
        [ ! -f "$f" ] && [ -f "$SRC/$f" ] && cp "$SRC/$f" "$f"
    done
    sudo umount "$MNT"
    return 0
}

if copy_from_macos; then
    ok "macOS 파티션에서 설정/모델 복사 완료 (다운로드 생략!)"
else
    warn "macOS 파티션 접근 불가 (FileVault 또는 APFS 모듈 없음) — 직접 설정합니다"
fi

# config.py 없으면 대화형 생성
if [ ! -f config.py ]; then
    cp config.example.py config.py
    echo ""
    echo "  텔레그램 봇 설정이 필요합니다 (macOS 의 config.py 와 동일 값)"
    read -r -p "  TELEGRAM_TOKEN: " TOK
    read -r -p "  본인 텔레그램 숫자 ID: " UID_IN
    [ -n "$TOK" ] && sed -i "s|^TELEGRAM_TOKEN = .*|TELEGRAM_TOKEN = \"$TOK\"|" config.py
    [ -n "$UID_IN" ] && sed -i "s|^AUTHORIZED_USERS = .*|AUTHORIZED_USERS = [$UID_IN]|" config.py
fi

# 모델 없으면 다운로드
BEST=""
for f in models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf \
         models/Qwen3-30B-A3B-Instruct-2507-Q3_K_M.gguf \
         models/Qwen_Qwen3-8B-Q4_K_M.gguf; do
    [ -f "$f" ] && BEST="$DIR/$f" && break
done
if [ -z "$BEST" ]; then
    info "모델 다운로드 (Qwen3-30B-A3B Q4_K_M, ~18.6GB)"
    pip install -q "huggingface_hub[cli]"
    hf download unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF \
        Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf --local-dir models 2>/dev/null \
    || huggingface-cli download unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF \
        Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf --local-dir models
    BEST="$DIR/models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
fi
sed -i "s|^MODEL_MAIN = .*|MODEL_MAIN = \"$BEST\"|" config.py
sed -i "s|^MODEL_HQ   = .*|MODEL_HQ   = \"$BEST\"|" config.py 2>/dev/null || true
ok "모델: $(basename "$BEST")"

# ── 5. systemd 부팅 자동 시작 등록 ───────────────────────────
info "[5/5] systemd 자동 시작 등록"
sudo tee /etc/systemd/system/ai-employee.service >/dev/null <<EOF
[Unit]
Description=AI Employee System (LLM + Telegram bot, ROCm GPU)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$DIR
Environment=HSA_OVERRIDE_GFX_VERSION=10.1.0
ExecStart=/bin/bash $DIR/start_linux.sh
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable ai-employee.service
ok "부팅 시 자동 시작 등록 완료"

# 즉시 시작
sudo systemctl restart ai-employee.service
echo "  LLM 서버 기동 대기 (GPU 모델 로딩, 최대 2분)..."
READY=0
for i in $(seq 1 60); do
    curl -s http://localhost:11434/health >/dev/null 2>&1 && { READY=1; break; }
    printf "."; sleep 2
done
echo ""

echo "============================================================"
if [ "$READY" = "1" ]; then
    ok "설치 완료! GPU 가속 AI 직원 시스템 가동 중"
    if grep -qiE "ROCm|HIP|gfx101" logs/llm.log 2>/dev/null; then
        echo "  GPU: ✅ ROCm (AMD Radeon Pro 5700 XT) — 드디어 GPU 사용!"
    else
        echo "  GPU: 확인 필요 — tail logs/llm.log"
    fi
    echo ""
    echo "  📱 텔레그램(@MImac_bot)에 메시지를 보내보세요."
    echo "  상태 확인: systemctl status ai-employee"
else
    warn "서버 대기 시간 초과 — 로그 확인: tail -f $DIR/logs/llm.log"
    echo "  GPU 권한 문제라면 재부팅 후 자동으로 다시 시작됩니다."
fi
echo "============================================================"
