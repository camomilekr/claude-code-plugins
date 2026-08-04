#!/usr/bin/env bash
# ClaudeCodeNotifier.app 빌드 스크립트 (macOS 전용)
#
# 알림을 클릭했을 때 IDE 로 포커스를 옮기려면 알림을 보내는 주체가 별도 앱이어야 한다.
# osascript 로 보내면 발신자가 스크립트 편집기가 되어 클릭 시 그쪽이 열린다.
# 이 앱은 UserNotifications 프레임워크로 알림을 띄우고, 클릭 시 userInfo 에 담긴
# 번들 ID 의 앱을 활성화한다.
#
# 요구사항: Xcode Command Line Tools (xcode-select --install)
# 결과물:   ~/.claude/ide-notify/ClaudeCodeNotifier.app
#
# notify.sh 가 앱이 없을 때 자동으로 한 번 호출한다. 수동 재빌드도 가능하다.
# 최초 실행 시 알림 권한 허용 프롬프트가 한 번 뜬다.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS 전용입니다." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc 가 없습니다. xcode-select --install 로 Command Line Tools 를 설치하세요." >&2
  exit 1
fi

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SELF_DIR")}"
SRC="$PLUGIN_ROOT/src/ClaudeCodeNotifier.swift"
APP="${CLAUDE_NOTIFIER_APP:-$HOME/.claude/ide-notify/ClaudeCodeNotifier.app}"
BUNDLE_ID="dev.claudecode.notifier"
EXEC_NAME="ClaudeCodeNotifier"

if [[ ! -f "$SRC" ]]; then
  echo "소스를 찾을 수 없습니다: $SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/$EXEC_NAME" "$SRC" \
  -framework Cocoa -framework UserNotifications

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Claude Code</string>
  <key>CFBundleDisplayName</key>       <string>Claude Code</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>$EXEC_NAME</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSUIElement</key>               <true/>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 정식 서명 인증서가 없어도 ad-hoc 서명으로 동작한다.
codesign --force --sign - "$APP"

# Launch Services 에 등록해 두면 알림 클릭 시 재실행이 확실해진다.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREG" ]] && "$LSREG" -f "$APP" || true

echo "빌드 완료: $APP"
