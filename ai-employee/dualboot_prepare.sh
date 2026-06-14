#!/bin/bash
# ============================================================
# 듀얼 부팅 1단계 — macOS 에서 실행하는 준비 스크립트
#
#   bash dualboot_prepare.sh [리눅스용 용량 GB, 기본 250]
#
# 하는 일:
#   1. T2 칩 / 디스크 여유 / FileVault 확인
#   2. t2linux Ubuntu ISO 다운로드 (iMac 2020 은 T2 칩 때문에
#      일반 Ubuntu ISO 로는 내장 SSD 인식 불가)
#   3. USB 부팅 디스크 제작 (16GB 이상 USB 필요)
#   4. WiFi/블루투스 펌웨어 추출 (Linux 에서 무선랜 쓰려면 필수)
#   5. APFS 파티션 축소 → Linux 용 빈 공간 확보
#
# 이후 수동 단계는 DUALBOOT_GUIDE.md 참고
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BOLD="\033[1m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $1${RESET}"; }
fail() { echo -e "${RED}❌ $1${RESET}"; }

LINUX_GB="${1:-250}"
WORK="$HOME/Downloads/t2ubuntu"
mkdir -p "$WORK"

echo -e "${BOLD}"
echo "============================================================"
echo "  iMac 듀얼 부팅 준비 — Ubuntu (t2linux) + macOS"
echo "  Linux 파티션 크기: ${LINUX_GB}GB"
echo "============================================================"
echo -e "${RESET}"

# ── 1. 시스템 확인 ───────────────────────────────────────────
info "[1/5] 시스템 확인"

MODEL_ID=$(sysctl -n hw.model)
echo "  모델: $MODEL_ID"
if system_profiler SPiBridgeDataType 2>/dev/null | grep -q "T2"; then
    ok "Apple T2 칩 있음 (iMac 2020 등) — t2linux 패치판 Ubuntu 사용"
    HAS_T2=1
else
    ok "T2 칩 없음 (iMac 2019 등) — 일반 Ubuntu 사용, 시동 보안 해제도 불필요!"
    HAS_T2=0
fi

# FileVault 켜져 있으면 Linux 에서 macOS 파티션(모델 파일) 못 읽음 — 경고만
if fdesetup status | grep -q "On"; then
    warn "FileVault 켜짐 — Linux 에서 macOS 의 모델 파일을 직접 못 읽으므로"
    echo "     Linux 쪽에서 모델을 새로 다운로드하게 됩니다 (자동 처리됨)."
fi

# 측정 전에 로컬 Time Machine 스냅샷을 정리한다.
# 스냅샷(purgeable)이 수십 GB 의 가용 공간을 점유하는데, 파티션 축소 때
# 어차피 비워야 하므로 미리 지워 실제 가용 공간을 확보한다.
info "로컬 Time Machine 스냅샷 정리 중 (공간 확보, 수 초 소요)..."
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c "com.apple" || true)
if [ "${SNAPS:-0}" -gt 0 ]; then
    tmutil deletelocalsnapshots / >/dev/null 2>&1 || \
        sudo tmutil deletelocalsnapshots / >/dev/null 2>&1 || true
    echo "  스냅샷 ${SNAPS}개 정리 완료"
    sleep 2
else
    echo "  정리할 스냅샷 없음"
fi

# 실제 여유 공간 파악.
# df 는 로컬 Time Machine 스냅샷을 "사용 중"으로 잡아 실제보다 적게 나오므로
# diskutil 의 Free Space(쉼표 제거)와 df 중 큰 값을 쓴다.
# (grep 실패가 set -e 로 스크립트를 죽이지 않도록 모두 || true)
DF_AVAIL=$(df -g / | awk 'NR==2{print $4}' || true)
DF_AVAIL=${DF_AVAIL:-0}
DI_OUT=$(diskutil info / 2>/dev/null || true)
# 쉼표 제거 후 6자리 이상 바이트 값만 추출 (첫 매치 = Container Free Space)
DU_BYTES=$(echo "$DI_OUT" | grep -Ei "Free Space|Available Space" \
           | tr -d ',' | grep -oE '[0-9]{6,} Bytes' | head -1 | grep -oE '[0-9]+' || true)
DU_AVAIL=$(( ${DU_BYTES:-0} / 1000000000 ))
AVAIL=$DF_AVAIL
[ "${DU_AVAIL:-0}" -gt "$AVAIL" ] && AVAIL=$DU_AVAIL
echo "  디스크 여유: ${AVAIL}GB (df=${DF_AVAIL}GB, diskutil=${DU_AVAIL}GB 중 큰 값)"
NEED=$((LINUX_GB + 30))   # macOS 쪽에도 최소 30GB 여유 유지
if [ "$AVAIL" -lt "$NEED" ]; then
    fail "여유 공간 부족: Linux ${LINUX_GB}GB + macOS 여유 30GB = ${NEED}GB 필요, 현재 ${AVAIL}GB"
    echo "  bash dualboot_prepare.sh 150  처럼 작은 크기로 다시 실행하거나 공간을 비우세요."
    exit 1
fi
ok "공간 충분 (${AVAIL}GB 확인)"

echo ""
warn "시작 전에 Time Machine 등으로 백업을 권장합니다. 파티션 작업은 되돌리기 어렵습니다."
read -r -p "  계속하시겠습니까? (yes 입력): " GO
[ "$GO" != "yes" ] && echo "중단됨" && exit 0

# ── 2. Ubuntu ISO 다운로드 (T2 유무에 따라 자동 선택) ────────
ISO="$WORK/ubuntu-imac.iso"

# 이미 받아둔 ISO 가 있어도 크기가 9GB 초과면 잘못된 파일로 보고 다시 받는다
# (t2linux/Ubuntu ISO 는 정상 시 4~7GB — 여러 ISO 잘못 합쳐진 경우 자동 삭제)
if [ -f "$ISO" ]; then
    ISO_GB=$(du -g "$ISO" | cut -f1)
    if [ "${ISO_GB:-0}" -gt 9 ]; then
        warn "ISO 크기 이상 (${ISO_GB}GB — 잘못된 다운로드). 삭제 후 재다운로드합니다."
        rm -f "$ISO" "$WORK"/*.iso* 2>/dev/null || true
    fi
fi

if [ -f "$ISO" ]; then
    ISO_GB=$(du -g "$ISO" | cut -f1)
    info "[2/5] ISO 이미 다운로드됨 (${ISO_GB}GB) — 건너뜀"
elif [ "$HAS_T2" = "1" ]; then
    info "[2/5] t2linux Ubuntu ISO 다운로드 (T2 맥 전용 패치판)"
    API="https://api.github.com/repos/t2linux/T2-Ubuntu/releases/latest"
    echo "  최신 릴리스 확인 중..."
    ALL_ASSET_URLS=$(curl -fsSL "$API" \
        | grep -oE '"browser_download_url": *"[^"]+"' \
        | grep -oE 'https://[^"]+' \
        | grep -E '\.(iso|iso\.[0-9a-z]+)$' | sort || true)
    if [ -z "$ALL_ASSET_URLS" ]; then
        fail "릴리스 조회 실패. 수동 다운로드: https://github.com/t2linux/T2-Ubuntu/releases"
        exit 1
    fi
    # 분할 파일이 있으면 첫 번째 ISO 시리즈만 선택 (여러 ISO 섞임 방지)
    if echo "$ALL_ASSET_URLS" | grep -qE '\.iso\.[0-9]+$'; then
        BASE_URL=$(echo "$ALL_ASSET_URLS" | grep -E '\.iso\.[0-9]+$' | head -1 | sed -E 's/\.[0-9]+$//')
        URLS=$(echo "$ALL_ASSET_URLS" | grep "^${BASE_URL}")
    else
        URLS=$(echo "$ALL_ASSET_URLS" | grep -E '\.iso$' | head -1)
    fi
    N=$(echo "$URLS" | wc -l | tr -d ' ')
    echo "  파일 ${N}개 다운로드 (총 4~7GB, 시간 소요)..."
    cd "$WORK"
    for U in $URLS; do
        echo "  ↓ $(basename "$U")"
        curl -fL -C - -O "$U"
    done
    if ls ./*.iso.[0-9]* >/dev/null 2>&1; then
        echo "  분할 파일 합치는 중..."
        cat ./*.iso.[0-9]* > "$ISO"
        rm -f ./*.iso.[0-9]*
    else
        FIRST=$(ls ./*.iso 2>/dev/null | grep -v "ubuntu-imac.iso" | head -1 || true)
        [ -n "$FIRST" ] && [ "$FIRST" != "$ISO" ] && mv "$FIRST" "$ISO"
    fi
    ISO_GB=$(du -g "$ISO" 2>/dev/null | cut -f1 || echo 0)
    if [ "${ISO_GB:-0}" -gt 9 ]; then
        fail "ISO 크기 이상: ${ISO_GB}GB — 다운로드 오류. 다시 실행해 보세요."
        exit 1
    fi
    ok "ISO 준비 완료: $ISO ($(du -h "$ISO" | cut -f1))"
else
    info "[2/5] Ubuntu 24.04 LTS 공식 ISO 다운로드 (T2 없는 맥은 일반판 사용)"
    BASE="https://releases.ubuntu.com/24.04"
    FNAME=$(curl -fsSL "$BASE/" | grep -oE 'ubuntu-24\.04[0-9.]*-desktop-amd64\.iso' | head -1)
    [ -z "$FNAME" ] && fail "ISO 목록 조회 실패: $BASE" && exit 1
    echo "  ↓ $FNAME (~6GB)"
    curl -fL -C - -o "$ISO" "$BASE/$FNAME"
    ok "ISO 준비 완료: $ISO ($(du -h "$ISO" | cut -f1))"
fi

# ── 3. USB 부팅 디스크 제작 ──────────────────────────────────
info "[3/5] USB 부팅 디스크 제작 (16GB 이상 USB 를 꽂으세요)"
echo ""
diskutil list external physical || true
echo ""
read -r -p "  USB 디스크 식별자 입력 (예: disk4, 건너뛰려면 엔터): " USB

if [ -n "$USB" ]; then
    USB="${USB#/dev/}"
    diskutil info "$USB" >/dev/null 2>&1 || { fail "디스크 없음: $USB"; exit 1; }
    if [ "$(diskutil info "$USB" | awk -F': *' '/Internal/{print $2}' | head -1 | xargs)" = "Yes" ]; then
        fail "$USB 는 내장 디스크입니다! 외장 USB 를 지정하세요."
        exit 1
    fi
    echo ""
    warn "$USB 의 모든 데이터가 지워집니다!"
    diskutil info "$USB" | grep -E "Device / Media Name|Disk Size" | sed 's/^/    /'
    read -r -p "  정말 지우고 USB 부팅 디스크를 만들까요? (ERASE 입력): " C
    if [ "$C" = "ERASE" ]; then
        # ISO 가 USB 에 들어가는지 크기 확인
        ISO_BYTES=$(stat -f%z "$ISO" 2>/dev/null || stat -c%s "$ISO" 2>/dev/null || echo 0)
        USB_BYTES=$(diskutil info "$USB" | tr -d ',' | grep -oE 'Disk Size: *[0-9]+ Bytes' | grep -oE '[0-9]+ Bytes' | head -1 | grep -oE '^[0-9]+' || echo 0)
        if [ "${ISO_BYTES:-0}" -gt "${USB_BYTES:-0}" ] && [ "${USB_BYTES:-0}" -gt 0 ]; then
            ISO_H=$(du -h "$ISO" | cut -f1)
            USB_H=$(diskutil info "$USB" | grep "Disk Size" | head -1 | grep -oE '[0-9.]+ GB' | head -1)
            fail "ISO(${ISO_H})가 USB(${USB_H:-$USB})보다 큽니다. 더 큰 USB가 필요합니다."
            exit 1
        fi
        diskutil unmountDisk force "/dev/$USB"
        echo "  기록 중 (10~20분, 진행 표시 없어도 정상)..."
        sudo dd if="$ISO" of="/dev/r$USB" bs=4m
        sync
        ok "USB 부팅 디스크 완성"
        diskutil eject "/dev/$USB" 2>/dev/null || true
    else
        warn "USB 제작 건너뜀"
    fi
else
    warn "USB 제작 건너뜀 — 나중에 이 스크립트를 다시 실행하면 됩니다 (ISO 재다운로드 안 함)"
fi

# ── 4. WiFi/블루투스 펌웨어 추출 (T2 맥만 필요) ──────────────
if [ "$HAS_T2" = "1" ]; then
    info "[4/5] WiFi/블루투스 펌웨어 추출 (t2linux 공식 스크립트)"
    echo "  Linux 는 맥 무선랜 펌웨어를 macOS 에서 가져와야 합니다."
    echo "  곧 나오는 질문에서 기본값(엔터)을 선택하면 EFI 파티션에 저장되고,"
    echo "  Ubuntu 설치 후 자동으로 인식됩니다."
    echo ""
    # 옵션 1(EFI 파티션에 저장)을 자동 선택해 비대화형으로 실행
    curl -fsSL https://wiki.t2linux.org/tools/firmware.sh -o /tmp/t2_firmware.sh || true
    if [ -f /tmp/t2_firmware.sh ]; then
        echo "1" | bash /tmp/t2_firmware.sh || \
            warn "펌웨어 추출 실패 — 설치 후 유선랜으로 인터넷 연결하면 우회 가능"
    else
        warn "펌웨어 스크립트 다운로드 실패 — 설치 후 유선랜으로 우회 가능"
    fi
else
    info "[4/5] 펌웨어 추출 건너뜀 (T2 없음)"
    echo "  설치 중 WiFi 가 안 잡히면 아이맥 뒷면 유선랜(이더넷)을 연결하세요."
    echo "  설치 옵션에서 '서드파티 드라이버 설치'를 체크하면 WiFi 가 잡힙니다."
fi

# 텔레그램 /switch (OS 전환) 도구 — macOS 쪽 설치
if [ -f "$DIR/setup_os_switch.sh" ]; then
    bash "$DIR/setup_os_switch.sh" || \
        warn "OS 전환 도구 설치 실패 — 나중에 setup_os_switch.sh 를 직접 실행하세요"
else
    warn "setup_os_switch.sh 없음 — git pull 후 재실행하면 자동 설치됩니다"
fi

# ── 5. APFS 파티션 축소 ──────────────────────────────────────
info "[5/5] APFS 파티션 ${LINUX_GB}GB 축소 → Linux 용 빈 공간 확보"

CONT=$(diskutil info / | awk -F': *' '/Part of Whole/{print $2}' | xargs)
CONT_BYTES=$(diskutil info "$CONT" | grep "Disk Size" | grep -oE '\(([0-9]+) Bytes' | grep -oE '[0-9]+')
CONT_GB=$((CONT_BYTES / 1000000000))
NEW_GB=$((CONT_GB - LINUX_GB))
echo "  컨테이너: $CONT (${CONT_GB}GB) → ${NEW_GB}GB 로 축소"
echo ""
read -r -p "  파티션을 지금 축소할까요? (yes 입력): " SH
if [ "$SH" = "yes" ]; then
    echo "  로컬 스냅샷 정리 중 (축소 실패 방지)..."
    tmutil deletelocalsnapshots / 2>/dev/null || true
    echo "  축소 중 (수 분 소요)..."
    if sudo diskutil apfs resizeContainer "$CONT" "${NEW_GB}g"; then
        ok "축소 완료 — ${LINUX_GB}GB 빈 공간 확보"
    else
        fail "축소 실패. 흔한 원인: 스냅샷/파일 단편화"
        echo "  → 재부팅 후 다시 실행하거나, 더 작은 크기로 시도하세요."
        exit 1
    fi
else
    warn "파티션 축소 건너뜀 — Ubuntu 설치 전에 반드시 필요합니다"
fi

# ── 완료 안내 ────────────────────────────────────────────────
echo ""
echo "============================================================"
ok "macOS 쪽 준비 끝! 다음은 수동 단계입니다 (DUALBOOT_GUIDE.md)"
echo ""
if [ "$HAS_T2" = "1" ]; then
    echo "  ① 재시동 → 즉시 Cmd(⌘)+R 꾹 → 복구 모드"
    echo "     유틸리티 메뉴 > 시동 보안 유틸리티:"
    echo "       - 보안 없음(No Security) 선택"
    echo "       - 외부 미디어 부팅 허용 선택"
    echo "  ② 재시동 → 즉시 Option(⌥) 꾹 → 'EFI Boot'(USB) 선택"
else
    echo "  ① (T2 없음 — 시동 보안 해제 단계 불필요!)"
    echo "  ② 재시동 → 즉시 Option(⌥) 꾹 → 'EFI Boot'(USB) 선택"
fi
echo "  ③ Ubuntu 설치 (빈 공간에 설치, APFS 파티션은 건드리지 말 것)"
echo "  ④ Ubuntu 부팅 후:"
echo "     git clone https://github.com/kakaka79da/mkang ~/mkang"
echo "     bash ~/mkang/ai-employee/linux_ai_setup.sh"
echo ""
echo "  설치가 끝나면 텔레그램 /switch yes 로 OS 를 오갈 수 있습니다."
echo "============================================================"
