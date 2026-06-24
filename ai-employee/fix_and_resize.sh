#!/bin/bash
# ============================================================
# fix_and_resize.sh — APFS 파티션 축소 (비대화형)
#
#   bash ~/mkang/ai-employee/fix_and_resize.sh 180
#
# 스냅샷 삭제 → 파티션 축소 → 실패시 재부팅 안내
# ============================================================
set -e

LINUX_GB="${1:-180}"
MACOS_GB=$((1000 - LINUX_GB))
DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BOLD="\033[1m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }

echo ""
echo -e "${BOLD}================================================================${RESET}"
echo "  APFS 파티션 축소 — Linux ${LINUX_GB}GB 확보"
echo -e "${BOLD}================================================================${RESET}"

# sudo 한 번만 입력
sudo -v || { fail "sudo 권한 필요"; exit 1; }

info "[1] Time Machine 비활성화 + 스냅샷 전체 삭제..."
sudo tmutil disable 2>/dev/null || true
sudo tmutil deletelocalsnapshots / 2>/dev/null || true
sudo tmutil deletelocalsnapshots /System/Volumes/Data 2>/dev/null || true
for snap in $(tmutil listlocalsnapshotdates 2>/dev/null | grep -v "^$"); do
    sudo tmutil deletelocalsnapshots "$snap" 2>/dev/null || true
done
sleep 3
REMAIN=$(tmutil listlocalsnapshotdates 2>/dev/null | grep -v "^$" | wc -l | tr -d ' ')
echo "  남은 스냅샷: ${REMAIN}개"

info "[2] 파티션 축소 시도 (→ ${MACOS_GB}GB)..."
set +e
RESIZE_RC=0
RESIZE_OUT=$(sudo diskutil apfs resizeContainer disk1 ${MACOS_GB}g 2>&1) || RESIZE_RC=$?
echo "$RESIZE_OUT" | tail -6
set -e

if [ "$RESIZE_RC" = "0" ]; then
    ok "🎉 파티션 축소 성공! ${LINUX_GB}GB 빈 공간 확보됨"
    sudo tmutil enable 2>/dev/null || true
    echo ""
    info "다음 단계: Cruzer Edge USB 꽂고 재시동 → Option(⌥) 꾹 → EFI Boot 선택"
    exit 0
fi

echo ""
fail "파티션 축소 실패 (종료코드 $RESIZE_RC)"

if echo "$RESIZE_OUT" | grep -q "69521"; then
    echo ""
    echo "  → 재부팅 후 아래 명령 실행:"
    echo "     sudo reboot"
    echo "     # 재부팅 후:"
    echo "     bash ~/mkang/ai-employee/fix_and_resize.sh ${LINUX_GB}"
    sudo tmutil enable 2>/dev/null || true
elif echo "$RESIZE_OUT" | grep -qiE "69716|corrupt|verify"; then
    echo ""
    echo "  → 복구 모드 터미널에서:"
    echo "     fsck_apfs -y /dev/disk0s2"
    echo "     재부팅 후 다시 실행"
    sudo tmutil enable 2>/dev/null || true
else
    sudo tmutil enable 2>/dev/null || true
fi

exit $RESIZE_RC
