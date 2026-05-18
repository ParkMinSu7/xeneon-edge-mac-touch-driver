#!/bin/bash
# 분석기 즉시 실행
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=$(uname -m)
TARGET="arm64-apple-macos13.0"
[ "$ARCH" != "arm64" ] && TARGET="x86_64-apple-macos13.0"
echo "빌드 중..."
swiftc "$SCRIPT_DIR/XeneonAnalyzer.swift" \
    -o /tmp/XeneonAnalyzer_test \
    -framework IOKit -framework Foundation \
    -target "$TARGET"
echo "실행 (Ctrl+C 종료)..."
exec /tmp/XeneonAnalyzer_test
