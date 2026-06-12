#!/bin/bash
# ============================================================
# Qwen3-30B-A3B-Instruct-2507 모델로 전환
# MoE 3.3B 활성 파라미터 → CPU에서 10~15 t/s (현재 8B의 3배)
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
err()  { echo -e "${RED}❌ $1${RESET}"; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$DIR/models"
mkdir -p "$MODEL_DIR"

REPO="unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"

# 디스크 여유에 따라 양자화 선택
AVAIL=$(df -g "$HOME" | awk 'NR==2{print $4}')
echo ""
echo "  디스크 여유: ${AVAIL}GB"
if [ "$AVAIL" -ge 20 ]; then
    FILE="Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
    echo "  → Q4_K_M 선택 (~18.6GB, 최고 품질)"
elif [ "$AVAIL" -ge 16 ]; then
    FILE="Qwen3-30B-A3B-Instruct-2507-Q3_K_M.gguf"
    echo "  → Q3_K_M 선택 (~14.7GB, 절충)"
else
    err "디스크 여유가 부족합니다 (${AVAIL}GB). 최소 16GB 필요."
fi

MODEL_PATH="$MODEL_DIR/$FILE"

# 1. HF CLI 확인
info "Step 1: HuggingFace CLI 확인"
source "$DIR/venv/bin/activate" 2>/dev/null || true
if command -v hf &>/dev/null; then
    HF_CMD="hf"
elif command -v huggingface-cli &>/dev/null; then
    HF_CMD="huggingface-cli"
else
    pip install -q "huggingface_hub[cli]"
    if command -v hf &>/dev/null; then HF_CMD="hf"; else HF_CMD="huggingface-cli"; fi
fi
ok "HF 명령어: $HF_CMD"

# 2. 다운로드
info "Step 2: 모델 다운로드 (시간 소요)"
if [ -f "$MODEL_PATH" ]; then
    ok "이미 존재: $MODEL_PATH — 다운로드 생략"
else
    echo "  다운로드 중: $REPO / $FILE"
    echo "  (Q4_K_M 기준 ~18.6GB, 30분~1시간 소요)"
    "$HF_CMD" download "$REPO" "$FILE" --local-dir "$MODEL_DIR"
    ok "다운로드 완료: $MODEL_PATH"
fi

# 3. config.py 업데이트
info "Step 3: config.py 모델 경로 업데이트"
if [ -f "$DIR/config.py" ]; then
    # 기존 MODEL_MAIN 줄 백업 후 교체
    sed -i '' "s|^MODEL_MAIN = .*|MODEL_MAIN = \"$MODEL_PATH\"|" "$DIR/config.py"
    ok "config.py 업데이트 완료"
    grep "MODEL_MAIN" "$DIR/config.py"
else
    echo "  config.py 없음 — config.example.py 에만 기록"
fi

# 4. 서비스 재시작
info "Step 4: AI 직원 시스템 재시작"
if [ -f "$DIR/stop.sh" ]; then
    bash "$DIR/stop.sh" 2>/dev/null || true
    sleep 2
fi
bash "$DIR/start.sh" &
START_PID=$!

# 서버 준비 대기
echo "  LLM 서버 준비 대기 중..."
for i in $(seq 1 40); do
    if curl -s http://localhost:11434/health > /dev/null 2>&1; then
        echo ""
        ok "LLM 서버 준비 완료"
        break
    fi
    printf "."
    sleep 3
done

echo ""
echo "=================================================="
ok "Qwen3-30B-A3B-Instruct-2507 전환 완료!"
echo "=================================================="
echo ""
echo "  모델: $MODEL_PATH"
echo "  예상 속도: 10~15 t/s (기존 8B의 약 3배)"
echo ""
echo "  텔레그램에서 테스트: 아무 메시지나 보내보세요."
echo ""
echo "  로그 확인:"
echo "    tail -f $DIR/logs/llm.log"
