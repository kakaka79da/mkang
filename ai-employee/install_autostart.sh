#!/bin/bash
# AI 직원 시스템 — macOS 부팅 자동 실행 등록/해제
#
# 등록:  bash install_autostart.sh
# 해제:  bash install_autostart.sh uninstall
# 상태:  bash install_autostart.sh status

DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$DIR/launchd/com.aiemployee.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.aiemployee.plist"
LABEL="com.aiemployee"

case "${1:-install}" in

install)
    if [ ! -f "$PLIST_SRC" ]; then
        echo "❌ plist 소스 없음: $PLIST_SRC"
        exit 1
    fi
    mkdir -p "$DIR/logs"
    sed -e "s|REPLACE_WITH_FULL_PATH|$DIR|g" \
        -e "s|REPLACE_WITH_HOME|$HOME|g" \
        "$PLIST_SRC" > "$PLIST_DST"
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    launchctl load "$PLIST_DST"
    echo "✅ 자동 실행 등록 완료"
    echo "   재부팅 후에도 AI 직원 시스템이 자동으로 켜집니다."
    echo "   로그: $DIR/logs/launchd_err.log"
    ;;

uninstall)
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "✅ 자동 실행 해제 완료"
    ;;

status)
    echo "=== launchd 상태 ==="
    launchctl list | grep "$LABEL" || echo "  (등록 안 됨)"
    echo ""
    echo "=== plist 설치 위치 ==="
    if [ -f "$PLIST_DST" ]; then
        echo "  ✅ $PLIST_DST"
    else
        echo "  ❌ 없음 — install 로 등록하세요"
    fi
    echo ""
    echo "=== 최근 오류 로그 ==="
    if [ -f "$DIR/logs/launchd_err.log" ]; then
        tail -20 "$DIR/logs/launchd_err.log"
    else
        echo "  (로그 없음)"
    fi
    ;;

*)
    echo "사용법: $0 [install|uninstall|status]"
    ;;
esac
