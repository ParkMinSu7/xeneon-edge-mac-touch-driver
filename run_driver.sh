#!/bin/bash
# 설치 없이 즉시 실행 (테스트용)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=$(uname -m)
TARGET="arm64-apple-macos13.0"
[ "$ARCH" != "arm64" ] && TARGET="x86_64-apple-macos13.0"
echo "빌드 중..."
swiftc "$SCRIPT_DIR/XeneonTouchDriver.swift" \
    -o /tmp/XeneonTouchDriver_test \
    -framework IOKit -framework CoreGraphics -framework Foundation -framework AppKit \
    -target "$TARGET" -O
echo "실행 (Ctrl+C 종료)..."
exec /tmp/XeneonTouchDriver_test
