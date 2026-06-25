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

# tmutil 방식
sudo tmutil deletelocalsnapshots / 2>/dev/null || true
sudo tmutil deletelocalsnapshots /System/Volumes/Data 2>/dev/null || true
for snap in $(tmutil listlocalsnapshotdates 2>/dev/null | grep -v "^$"); do
    sudo tmutil deletelocalsnapshots "$snap" 2>/dev/null || true
done

# diskutil apfs 방식 — 모든 APFS 볼륨의 스냅샷 직접 삭제
for vol in disk1s1 disk1s2 disk1s3 disk1s4 disk1s5 disk1s6; do
    for snapname in $(diskutil apfs listSnapshots "$vol" 2>/dev/null \
                      | awk '/Name:/{print $2}'); do
        sudo diskutil apfs deleteSnapshot "$vol" -name "$snapname" 2>/dev/null || true
    done
done

sleep 3
REMAIN=$(tmutil listlocalsnapshotdates 2>/dev/null | grep -v "^$" | wc -l | tr -d ' ')
echo "  남은 스냅샷: ${REMAIN}개"

if [ "$REMAIN" != "0" ]; then
    echo ""
    echo "  ⚠️  스냅샷이 아직 남아 있습니다. 재부팅 후 다시 시도하세요:"
    echo "     sudo reboot"
    echo "     # 재부팅 후:"
    echo "     bash ~/mkang/ai-employee/fix_and_resize.sh ${LINUX_GB}"
    sudo tmutil enable 2>/dev/null || true
    exit 1
fi

info "[2] 파티션 축소 시도 (→ ${MACOS_GB}GB)..."
set +e
RESIZE_RC=0
RESIZE_OUT=$(sudo diskutil apfs resizeContainer disk1 ${MACOS_GB}g 2>&1) || RESIZE_RC=$?
echo "$RESIZE_OUT" | tail -8
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
elif echo "$RESIZE_OUT" | grep -qiE "69716|corrupt|verify|exit code is 8"; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ⚠️  파일시스템 손상 (-69716) — Recovery Mode 수리 필요"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  1. iMac 종료 → 전원 버튼 길게 눌러 재시동"
    echo "     → '로딩 중' 화면에서 손 떼기 → Options 선택"
    echo "     (또는 전원 켜자마자 Cmd+R 길게)"
    echo ""
    echo "  2. Recovery Mode 터미널 열기 → 아래 명령 실행:"
    echo ""
    echo "     fsck_apfs -y /dev/disk0s2"
    echo ""
    echo "  3. 'The volume /dev/disk0s2 appears to be OK' 메시지 확인"
    echo "     → Apple 메뉴 → 재시동"
    echo ""
    echo "  4. 재시동 후 macOS 터미널에서:"
    echo "     bash ~/mkang/ai-employee/fix_and_resize.sh ${LINUX_GB}"
    echo ""
    sudo tmutil enable 2>/dev/null || true
else
    sudo tmutil enable 2>/dev/null || true
fi

exit $RESIZE_RC
