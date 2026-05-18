#!/bin/bash
PLIST="$HOME/Library/LaunchAgents/com.xeneontouch.driver.plist"
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f XeneonTouchDriver 2>/dev/null || true
sudo rm -f /usr/local/bin/XeneonTouchDriver /usr/local/bin/XeneonAnalyzer
rm -f "$PLIST" /tmp/xeneontouch.log
echo "✓ 제거 완료. 시스템 설정 → 개인정보에서 항목도 직접 삭제해주세요."
