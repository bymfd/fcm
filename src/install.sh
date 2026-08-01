#!/bin/bash
# install.sh — runs as root (elevated via osascript)
RES="$1"
set -e

mkdir -p /Library/PrivilegedHelperTools
cp "$RES/smc" /Library/PrivilegedHelperTools/fcm-smc
chmod 755 /Library/PrivilegedHelperTools/fcm-smc
cp "$RES/helper.sh" /Library/PrivilegedHelperTools/fcm-helper.sh
chmod 755 /Library/PrivilegedHelperTools/fcm-helper.sh

cat > /Library/LaunchDaemons/com.fcm.helper.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fcm.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/fcm-helper.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST
chmod 644 /Library/LaunchDaemons/com.fcm.helper.plist
launchctl unload /Library/LaunchDaemons/com.fcm.helper.plist 2>/dev/null || true
launchctl load -w /Library/LaunchDaemons/com.fcm.helper.plist
