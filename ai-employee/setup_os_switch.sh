#!/bin/bash
# ============================================================
# 텔레그램 /switch 명령용 OS 전환 도구 설치
# macOS / Ubuntu 양쪽에서 각각 한 번씩 실행 (sudo 비번 1회 필요)
#
#   bash setup_os_switch.sh
#
# 설치 내용:
#   /usr/local/sbin/os-switch  — 반대편 OS로 1회 부팅 후 재부팅
#   sudoers 등록               — 봇이 비밀번호 없이 실행 가능
#
# 동작 원리:
#   macOS → Linux:  bless --nextonly 로 '다음 1회만' GRUB 부팅
#   Linux → macOS:  efibootmgr BootNext(애플 펌웨어 macOS=0080)
#   → 기본 부팅 OS 설정은 건드리지 않으므로 안전
# ============================================================
set -e

GREEN="\033[32m"; YELLOW="\033[33m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
info() { echo -e "${YELLOW}▶  $1${RESET}"; }

HELPER=/usr/local/sbin/os-switch
OS=$(uname -s)
TMP=$(mktemp)

if [ "$OS" = "Darwin" ]; then
    info "macOS 용 os-switch 설치 (다음 부팅 1회만 Ubuntu)"
    cat > "$TMP" <<'HELPER_EOF'
#!/bin/bash
# 다음 부팅 1회만 Ubuntu(GRUB)로 지정하고 재부팅 (기본값은 macOS 유지)
set -e
ESP=$(diskutil list internal | awk '/EFI/ {print $NF; exit}')
[ -n "$ESP" ] || { echo "EFI 파티션을 찾지 못했습니다"; exit 1; }
MP=$(diskutil info "$ESP" | sed -n 's/.*Mount Point: *//p' | head -1)
if [ -z "$MP" ] || [ ! -d "$MP" ]; then
    diskutil mount "$ESP" >/dev/null
    MP=$(diskutil info "$ESP" | sed -n 's/.*Mount Point: *//p' | head -1)
fi
LOADER=""
for f in "$MP/EFI/ubuntu/shimx64.efi" "$MP/EFI/ubuntu/grubx64.efi" "$MP/EFI/BOOT/BOOTX64.EFI"; do
    [ -f "$f" ] && LOADER="$f" && break
done
[ -n "$LOADER" ] || { echo "Ubuntu 부트로더가 없습니다 (Ubuntu 설치 전?)"; exit 1; }
bless --mount "$MP" --file "$LOADER" --setBoot --nextonly
shutdown -r now
HELPER_EOF
    sudo install -o root -g wheel -m 755 "$TMP" "$HELPER"
    echo "$USER ALL=(root) NOPASSWD: $HELPER" | sudo tee /etc/sudoers.d/ai-employee-osswitch >/dev/null
    sudo chmod 440 /etc/sudoers.d/ai-employee-osswitch

elif [ "$OS" = "Linux" ]; then
    info "Linux 용 os-switch 설치 (다음 부팅 1회만 macOS)"
    sudo apt-get install -y -q efibootmgr >/dev/null 2>&1 || true
    cat > "$TMP" <<'HELPER_EOF'
#!/bin/bash
# 다음 부팅 1회만 macOS 로 지정하고 재부팅
# 애플 인텔 펌웨어는 macOS 를 Boot0080 으로 노출한다
set -e
ENTRY=$(efibootmgr 2>/dev/null | grep -iE "mac" | head -1 \
        | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
for E in "$ENTRY" 0080; do
    [ -n "$E" ] || continue
    if efibootmgr -n "$E" >/dev/null 2>&1; then
        systemctl reboot
        exit 0
    fi
done
# 펌웨어가 BootNext 를 무시하는 경우: GRUB 의 macOS 엔트리로 1회 부팅
MAC_ENTRY=$(grep -iE "^menuentry ['\"].*(mac ?os|apple)" /boot/grub/grub.cfg 2>/dev/null \
            | head -1 | sed -E "s/menuentry ['\"]([^'\"]+).*/\1/")
if [ -n "$MAC_ENTRY" ]; then
    grub-reboot "$MAC_ENTRY"
    systemctl reboot
    exit 0
fi
echo "macOS 부팅 엔트리를 찾지 못했습니다. 재부팅 후 Option 키로 선택하세요."
exit 1
HELPER_EOF
    sudo install -o root -g root -m 755 "$TMP" "$HELPER"
    echo "$USER ALL=(root) NOPASSWD: $HELPER" | sudo tee /etc/sudoers.d/ai-employee-osswitch >/dev/null
    sudo chmod 440 /etc/sudoers.d/ai-employee-osswitch
else
    echo "지원하지 않는 OS: $OS"; exit 1
fi

rm -f "$TMP"
ok "설치 완료 — 텔레그램에서 /switch yes 로 OS 전환 가능"
echo "  (양쪽 OS 모두에 설치해야 왕복 전환이 됩니다)"
