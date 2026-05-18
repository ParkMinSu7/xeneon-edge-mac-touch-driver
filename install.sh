#!/bin/bash
# install.sh - XeneonTouchDriver 빌드 및 설치
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_SRC="$SCRIPT_DIR/XeneonTouchDriver.swift"
ANALYZER_SRC="$SCRIPT_DIR/XeneonAnalyzer.swift"
INSTALL_BIN="/usr/local/bin"
PLIST="$HOME/Library/LaunchAgents/com.xeneontouch.driver.plist"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()  { echo -e "${GREEN}✓  $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠  $1${NC}"; }
die() { echo -e "${RED}✗  $1${NC}" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    Xeneon Touch Driver 설치                  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

command -v swiftc >/dev/null || die "swiftc 없음 → xcode-select --install"
[ -f "$DRIVER_SRC" ] || die "파일 없음: $DRIVER_SRC"

ARCH=$(uname -m)
TARGET="arm64-apple-macos13.0"
[ "$ARCH" != "arm64" ] && TARGET="x86_64-apple-macos13.0"
echo "아키텍처: $ARCH  Target: $TARGET"
echo ""

# ── 드라이버 컴파일 ──────────────────────────────────────────────────────────
echo "▶ 드라이버 컴파일..."
swiftc "$DRIVER_SRC" \
    -o /tmp/XeneonTouchDriver_new \
    -framework IOKit \
    -framework CoreGraphics \
    -framework Foundation \
    -framework AppKit \
    -target "$TARGET" -O
ok "컴파일 완료"

# ── 분석기 컴파일 ────────────────────────────────────────────────────────────
if [ -f "$ANALYZER_SRC" ]; then
    echo "▶ 분석기 컴파일..."
    swiftc "$ANALYZER_SRC" \
        -o /tmp/XeneonAnalyzer_new \
        -framework IOKit -framework Foundation \
        -target "$TARGET" 2>/dev/null && ok "분석기 컴파일 완료" || warn "분석기 컴파일 실패 (무시)"
fi

# ── 기존 드라이버 중지 ───────────────────────────────────────────────────────
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f XeneonTouchDriver 2>/dev/null || true
sleep 0.5

# ── 설치 ────────────────────────────────────────────────────────────────────
echo "▶ 설치 중..."
sudo install -m 755 /tmp/XeneonTouchDriver_new "$INSTALL_BIN/XeneonTouchDriver"
[ -f /tmp/XeneonAnalyzer_new ] && sudo install -m 755 /tmp/XeneonAnalyzer_new "$INSTALL_BIN/XeneonAnalyzer" || true
ok "바이너리 설치: $INSTALL_BIN"

# ── LaunchAgent ──────────────────────────────────────────────────────────────
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xeneontouch.driver</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_BIN/XeneonTouchDriver</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/xeneontouch.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/xeneontouch.log</string>
    <key>ThrottleInterval</key>
    <integer>5</integer>
</dict>
</plist>
EOF
ok "LaunchAgent: $PLIST"

# ── 권한 안내 ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ⚠️  macOS 권한 설정 필요 (두 곳 모두)                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  1. 시스템 설정 → 개인정보 → 입력 모니터링                  ║"
echo "║     + 버튼 → /usr/local/bin/XeneonTouchDriver 추가           ║"
echo "║                                                              ║"
echo "║  2. 시스템 설정 → 개인정보 → 손쉬운 사용                    ║"
echo "║     + 버튼 → /usr/local/bin/XeneonTouchDriver 추가           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
read -rp "위 권한 부여 완료 후 Enter..."

# ── 시작 ────────────────────────────────────────────────────────────────────
launchctl load "$PLIST"
sleep 2

if pgrep -f XeneonTouchDriver >/dev/null 2>&1; then
    ok "드라이버 실행 중!"
else
    warn "드라이버 미시작. 로그 확인: tail -f /tmp/xeneontouch.log"
    warn "수동 실행: $INSTALL_BIN/XeneonTouchDriver"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  로그:    tail -f /tmp/xeneontouch.log"
echo "  중지:    launchctl unload $PLIST"
echo "  시작:    launchctl load $PLIST"
echo "  제거:    ./uninstall.sh"
echo "  분석:    XeneonAnalyzer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
