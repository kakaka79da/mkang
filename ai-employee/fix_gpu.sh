#!/bin/bash
# ============================================================
# GPU 자동 진단 + 설정 — AMD Radeon Pro 5700 XT
#
# 실행: bash fix_gpu.sh
#
# 하는 일:
#   1. Vulkan 이 보는 GPU 장치 열거
#   2. 장치 필터 없이 / 0번 / 1번으로 실제 추론 테스트
#   3. GPU 출력 품질 검사 (gibberish 감지)
#   4. 결과를 gpu.env 에 저장 → start.sh 가 자동 사용
# ============================================================

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${CYAN}▶  $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
LLAMA_DIR="$HOME/llama.cpp"
VK_BENCH="$LLAMA_DIR/build-vulkan/bin/llama-bench"
VK_CLI="$LLAMA_DIR/build-vulkan/bin/llama-cli"

source venv/bin/activate 2>/dev/null || true
MODEL=$(python3 -c "from config import MODEL_MAIN; import os; print(os.path.expanduser(MODEL_MAIN))" 2>/dev/null)

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /usr/local)"
VK_ICD="$BREW_PREFIX/share/vulkan/icd.d/MoltenVK_icd.json"
if [ ! -f "$VK_ICD" ]; then
    ALT="$(find "$BREW_PREFIX" -name "MoltenVK_icd.json" 2>/dev/null | head -1)"
    [ -n "$ALT" ] && VK_ICD="$ALT"
fi
export VK_ICD_FILENAMES="$VK_ICD"
export DYLD_LIBRARY_PATH="$LLAMA_DIR/build-vulkan/bin:/usr/local/lib:${DYLD_LIBRARY_PATH:-}"

echo "============================================================"
echo "  GPU 자동 진단 — AMD Radeon Pro 5700 XT"
echo "============================================================"
echo "  모델: $(basename "$MODEL")"
echo "  ICD:  $VK_ICD"
echo ""

[ ! -f "$MODEL" ]   && fail "모델 파일 없음" && exit 1
[ ! -x "$VK_BENCH" ] && fail "Vulkan 빌드 없음 — bash build_vulkan.sh 먼저 실행" && exit 1
[ ! -f "$VK_ICD" ]  && fail "MoltenVK 없음 — brew install molten-vk" && exit 1

# ── Step 1: Vulkan 장치 열거 ─────────────────────────────────────────────────
info "Step 1: Vulkan 이 인식하는 GPU 목록"
if command -v vulkaninfo &>/dev/null; then
    vulkaninfo --summary 2>/dev/null | grep -E "deviceName|deviceType" | sed 's/^/    /' || echo "    (출력 없음)"
else
    echo "    (vulkaninfo 미설치 — brew install vulkan-tools)"
fi
echo ""

# ── Step 2: 장치 설정별 실제 추론 테스트 ──────────────────────────────────────
# "" = 필터 없음(전체 장치), "0", "1"
info "Step 2: 장치 설정별 GPU 추론 테스트 (각 ~1분)"

BEST_SETTING="__none__"
BEST_TPS=0

for DEV in "" "0" "1"; do
    LABEL="${DEV:-필터없음(전체)}"
    echo ""
    echo "  ─── GGML_VK_VISIBLE_DEVICES=$LABEL ───"

    if [ -n "$DEV" ]; then
        OUT=$(GGML_VK_VISIBLE_DEVICES="$DEV" "$VK_BENCH" -m "$MODEL" -ngl 99 -n 16 -p 32 -r 1 2>&1)
    else
        OUT=$(env -u GGML_VK_VISIBLE_DEVICES "$VK_BENCH" -m "$MODEL" -ngl 99 -n 16 -p 32 -r 1 2>&1)
    fi
    echo "$OUT" | grep -iE "ggml_vulkan|Vulkan[0-9]|deviceName|tg16|pp32|error" | head -6 | sed 's/^/    /'

    if echo "$OUT" | grep -qi "ggml_vulkan: Found"; then
        TPS=$(echo "$OUT" | grep "tg16" | grep -oE '[0-9]+\.[0-9]+' | tail -1)
        TPS="${TPS:-0}"
        ok "  GPU 인식됨! 생성 속도: ${TPS} t/s"
        if awk "BEGIN{exit !($TPS > $BEST_TPS)}"; then
            BEST_TPS="$TPS"; BEST_SETTING="$DEV"
        fi
    else
        warn "  GPU 미인식 (CPU 폴백)"
    fi
done

echo ""

# ── Step 3: 출력 품질 검사 (gibberish 감지) ──────────────────────────────────
GPU_OK=0
if [ "$BEST_SETTING" != "__none__" ]; then
    info "Step 3: GPU 출력 품질 검사 (깨진 출력 감지)"
    if [ -x "$VK_CLI" ]; then
        if [ -n "$BEST_SETTING" ]; then
            TXT=$(GGML_VK_VISIBLE_DEVICES="$BEST_SETTING" "$VK_CLI" -m "$MODEL" -ngl 99 \
                  -n 32 -p "대한민국의 수도는" --no-display-prompt -no-cnv 2>/dev/null | head -3)
        else
            TXT=$(env -u GGML_VK_VISIBLE_DEVICES "$VK_CLI" -m "$MODEL" -ngl 99 \
                  -n 32 -p "대한민국의 수도는" --no-display-prompt -no-cnv 2>/dev/null | head -3)
        fi
        echo "    출력: $TXT"
        QUALITY=$(python3 -c "
import sys
t = '''$TXT'''.strip()
if not t:
    print('empty'); sys.exit()
good = sum(1 for c in t if c.isalnum() or '가' <= c <= '힣' or c in ' .,!?\"\'()-:')
print('good' if good / max(len(t),1) > 0.6 else 'gibberish')
")
        case "$QUALITY" in
            good)      ok "출력 정상 — GPU 사용 가능!"; GPU_OK=1 ;;
            gibberish) fail "출력 깨짐(gibberish) — 이 GPU 는 macOS Vulkan 에서도 계산 오류 (#20104)" ;;
            empty)     warn "출력 없음 — GPU 불안정으로 판단" ;;
        esac
    else
        warn "llama-cli 없음 — 품질 검사 생략, 속도만으로 판단"
        GPU_OK=1
    fi
fi

# ── Step 4: 결과 저장 ────────────────────────────────────────────────────────
echo ""
echo "============================================================"
if [ "$GPU_OK" = "1" ]; then
    {
        echo "# fix_gpu.sh 가 자동 생성 — start.sh 가 읽음"
        echo "GPU_OK=1"
        echo "VK_DEVICE=\"$BEST_SETTING\""
    } > "$DIR/gpu.env"
    ok "GPU 사용 확정! (장치 설정: ${BEST_SETTING:-전체}, ${BEST_TPS} t/s)"
    echo ""
    echo "  지금 적용:  bash $DIR/stop.sh && bash $DIR/start.sh"
    echo "  이후 시작할 때마다 자동으로 GPU 모드로 켜집니다."
else
    {
        echo "# fix_gpu.sh 가 자동 생성 — start.sh 가 읽음"
        echo "GPU_OK=0"
        echo "VK_DEVICE=\"\""
    } > "$DIR/gpu.env"
    fail "결론: 이 하드웨어(Intel Mac + RDNA1)는 macOS 에서 GPU 추론 불가"
    echo ""
    echo "  - Metal: 깨진 출력 버그 (llama.cpp #19563, 수정 계획 없음)"
    echo "  - Vulkan/MoltenVK: $([ "$BEST_SETTING" = "__none__" ] && echo '장치 미인식' || echo '계산 오류(gibberish)')"
    echo ""
    echo "  현실적 대안:"
    echo "  1. CPU + MoE 모델 (Qwen3-30B-A3B) → 10~15 t/s, 지금 다운로드 중인 그 모델"
    echo "  2. 이 GPU 를 쓰려면 같은 컴퓨터에 Linux 설치 시 ROCm/Vulkan 정상 작동"
    echo ""
    echo "  start.sh 는 앞으로 GPU 시도를 건너뛰고 바로 CPU 로 시작합니다 (기동 30초 단축)."
fi
echo "============================================================"
