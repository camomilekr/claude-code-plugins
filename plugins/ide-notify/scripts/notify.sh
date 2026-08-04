#!/usr/bin/env bash
# ide-notify: Claude Code 시스템 알림 훅 (크로스플랫폼)
#
# 사용법: notify.sh <이벤트종류>
#   stop           - Claude 가 모든 작업을 마쳤을 때
#   subagent-start - 서브에이전트 하나가 작업을 시작했을 때
#   subagent-stop  - 서브에이전트 하나가 작업을 마쳤을 때
#   input          - 사용자의 승인/결정이 필요할 때
#
# 입력: stdin 으로 들어오는 훅 JSON 페이로드
#   Notification 이벤트는 .message 에 알림 문구가 담겨 있다.
#   SubagentStart/Stop 이벤트는 .agent_type 에 에이전트 이름이 담겨 있다.
#
# stop / subagent-stop 알림 문구
#   하드코딩 문구 대신 트랜스크립트(JSONL)에서 마지막 assistant 텍스트를
#   뽑아 작업 결과 요약으로 보여준다.
#   - stop: .transcript_path 의 메인 체인(isSidechain != true) 마지막 텍스트
#   - subagent-stop: <트랜스크립트>/subagents/agent-<id>.jsonl 의 마지막 텍스트
#   추출에 실패하면 기존 기본 문구로 폴백한다. (jq 필요)
#
# 지원 플랫폼: macOS(전용 앱 또는 osascript), Linux(notify-send),
#              WSL·Windows(PowerShell), 그 외에는 터미널 벨로 폴백한다.
#
# [macOS] 알림 클릭 시 IDE 로 포커스
#   알림 클릭 시 활성화되는 앱은 "알림을 보낸 앱"으로 정해지며 지정할 수 없다.
#   osascript 로 보내면 발신자가 스크립트 편집기가 되어 클릭 시 그쪽이 열린다.
#   그래서 UserNotifications 프레임워크를 쓰는 전용 앱을 빌드해 사용한다.
#   이 앱이 클릭을 받아 호스트 IDE 를 활성화한다. 앱이 없으면 처음 한 번
#   자동으로 빌드하고, 빌드할 수 없으면 osascript 로 폴백한다.
#
#   주의: terminal-notifier 는 쓰지 말 것. macOS 15+ 에서 제거된
#   NSUserNotification API 만 사용해 알림을 띄우지 못하면서도 종료 코드 0 을
#   반환하기 때문에, 알림이 안 뜨는데 성공으로 처리된다.
#
# 환경변수
#   CLAUDE_NOTIFY_BUNDLE_ID  클릭 시 포커스할 앱의 번들 ID 를 강제 지정 (macOS)
#   CLAUDE_NOTIFIER_APP      전용 알림 앱 경로 재정의 (macOS)
#   CLAUDE_NOTIFY_DEBUG=1    진단 로그를 ~/.claude/ide-notify/notifier.log 에 기록
#   CLAUDE_NOTIFY_NO_BUILD=1 전용 앱 자동 빌드를 끈다
#   CLAUDE_NOTIFY_DRY_RUN=1  알림을 띄우지 않고 문구만 stdout 으로 출력 (진단용)

set -uo pipefail

event=${1:-input}
payload=$(cat 2>/dev/null || true)

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SELF_DIR")}"
STATE_DIR="$HOME/.claude/ide-notify"

# --- 페이로드에서 알림 문구 추출 (jq 가 없거나 실패해도 진행) ---
msg=""
agent=""
tpath=""
agent_tpath=""
agent_id=""
if [[ -n "$payload" ]] && command -v jq >/dev/null 2>&1; then
  msg=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null) || msg=""
  agent=$(printf '%s' "$payload" | jq -r '.agent_type // empty' 2>/dev/null) || agent=""
  tpath=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null) || tpath=""
  agent_tpath=$(printf '%s' "$payload" | jq -r '.agent_transcript_path // empty' 2>/dev/null) || agent_tpath=""
  agent_id=$(printf '%s' "$payload" | jq -r '.agent_id // empty' 2>/dev/null) || agent_id=""
fi

# --- 트랜스크립트에서 마지막 assistant 텍스트를 요약 문구로 추출 ---
# $1: 트랜스크립트 경로, $2: 1 이면 사이드체인(서브에이전트) 항목도 포함
# 대형 트랜스크립트 대비 파일 꼬리 1MB 만 읽는다. 잘린 첫 줄은 fromjson? 이
# 조용히 버린다. 마크다운 장식(백틱·별표·헤딩)을 걷어내고 160자로 자른다.
summarize_transcript() {
  local path=$1 include_sidechain=${2:-0} out
  [[ -n "$path" && -r "$path" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$(tail -c 1048576 "$path" 2>/dev/null | jq -rRs --argjson sc "$include_sidechain" '
    [ split("\n")[]
      | fromjson?
      | select(.type == "assistant")
      | select($sc == 1 or .isSidechain != true)
      | .message.content
      | if type == "array"
        then ([ .[] | select(.type? == "text") | .text ] | join(" "))
        else tostring
        end
      | gsub("`+"; "")
      | gsub("\\*+"; "")
      | gsub("(^|\\n)#+ *"; " ")
      | gsub("\\s+"; " ")
      | sub("^ +"; "") | sub(" +$"; "")
      | select(length > 0)
    ] | last // empty
    | if length > 160 then .[0:159] + "…" else . end
  ' 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# --- subagent-stop: 방금 멈춘 에이전트의 트랜스크립트 경로를 찾는다 ---
# 1) 페이로드의 agent_transcript_path
# 2) <메인 트랜스크립트 디렉토리>/subagents/agent-<agent_id>.jsonl
# 3) 같은 디렉토리에서 가장 최근에 수정된 agent-*.jsonl
#    (SubagentStop 은 종료 직후 발화하므로 방금 멈춘 에이전트일 확률이 높다)
find_agent_transcript() {
  if [[ -n "$agent_tpath" && -r "$agent_tpath" ]]; then
    printf '%s' "$agent_tpath"; return 0
  fi
  [[ -n "$tpath" ]] || return 1
  local dir="${tpath%.jsonl}/subagents" latest
  [[ -d "$dir" ]] || return 1
  if [[ -n "$agent_id" && -r "$dir/agent-$agent_id.jsonl" ]]; then
    printf '%s' "$dir/agent-$agent_id.jsonl"; return 0
  fi
  latest=$(ls -t "$dir"/agent-*.jsonl 2>/dev/null | head -1)
  [[ -n "$latest" && -r "$latest" ]] || return 1
  printf '%s' "$latest"
}

# 이벤트별 알림 문구. stop/subagent-stop 은 트랜스크립트 요약을 우선 사용하고
# 실패 시 기본 문구로 폴백한다.
# ("subagent" 는 subagent-stop 의 옛 이름으로, 구버전 hooks.json 호환용)
case "$event" in
  stop)
    if [[ -z "$msg" ]]; then
      msg=$(summarize_transcript "$tpath" 0) || msg="작업을 모두 마쳤습니다."
    fi
    ;;
  subagent-start)
    msg="${agent:+$agent }서브에이전트가 작업을 시작했습니다."
    ;;
  subagent-stop|subagent)
    summary=""
    if agent_transcript=$(find_agent_transcript); then
      summary=$(summarize_transcript "$agent_transcript" 1) || summary=""
    fi
    if [[ -n "$summary" ]]; then
      msg="${agent:+$agent · }$summary"
    else
      msg="${agent:+$agent }서브에이전트가 작업을 마쳤습니다."
    fi
    ;;
  *)
    [[ -n "$msg" ]] || msg="확인이 필요합니다."
    ;;
esac

project=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")

# 각 플랫폼 명령에 값을 안전하게 넘기기 위해 환경변수로 전달한다.
# (문자열 보간을 피해야 따옴표·백슬래시가 섞여도 깨지지 않는다.)
export NOTIFY_TITLE="Claude Code"
export NOTIFY_SUBTITLE="$project"
export NOTIFY_BODY="$msg"

# 진단용: 알림을 띄우지 않고 문구만 출력한다.
if [[ "${CLAUDE_NOTIFY_DRY_RUN:-}" == "1" ]]; then
  printf '%s | %s | %s\n' "$NOTIFY_TITLE" "$NOTIFY_SUBTITLE" "$NOTIFY_BODY"
  exit 0
fi

# --- macOS: 이 세션을 띄운 앱(터미널/IDE)의 번들 ID 를 찾는다 ---
detect_bundle_id() {
  if [[ -n "${CLAUDE_NOTIFY_BUNDLE_ID:-}" ]]; then
    printf '%s' "$CLAUDE_NOTIFY_BUNDLE_ID"; return 0
  fi
  if [[ -n "${__CFBundleIdentifier:-}" ]]; then
    printf '%s' "$__CFBundleIdentifier"; return 0
  fi
  # 프로세스 조상을 거슬러 올라가 .app 번들을 찾고 Info.plist 에서 읽는다
  local pid=$$ i exe ppid app bid
  for ((i = 0; i < 12; i++)); do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    [[ -n "$exe" ]] || break
    if [[ "$exe" == *.app/Contents/MacOS/* ]]; then
      app="${exe%%.app/Contents/MacOS/*}.app"
      bid=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null)
      if [[ -n "$bid" ]]; then printf '%s' "$bid"; return 0; fi
    fi
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n "$ppid" ]] && [[ "$ppid" -gt 1 ]] 2>/dev/null || break
    pid=$ppid
  done
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) printf 'com.apple.Terminal' ;;
    iTerm.app)      printf 'com.googlecode.iterm2' ;;
    WezTerm)        printf 'com.github.wez.wezterm' ;;
    ghostty)        printf 'com.mitchellh.ghostty' ;;
    Hyper)          printf 'co.zeit.hyper' ;;
    *) return 1 ;;
  esac
}

# --- macOS: 전용 알림 앱이 없으면 한 번만 빌드한다 ---
# 실패 스탬프를 남겨 매 알림마다 빌드를 재시도하지 않는다.
ensure_notifier_app() {
  local app=$1
  [[ -x "$app/Contents/MacOS/ClaudeCodeNotifier" ]] && return 0
  [[ "${CLAUDE_NOTIFY_NO_BUILD:-}" == "1" ]] && return 1
  [[ -f "$STATE_DIR/.build-failed" ]] && return 1
  command -v swiftc >/dev/null 2>&1 || return 1
  local builder="$PLUGIN_ROOT/scripts/build-notifier.sh"
  [[ -x "$builder" ]] || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  if CLAUDE_NOTIFIER_APP="$app" "$builder" >/dev/null 2>&1; then
    return 0
  fi
  : > "$STATE_DIR/.build-failed"
  return 1
}

# --- Windows PowerShell 토스트 (WSL / Git Bash 공용) ---
notify_powershell() {
  local ps=$1
  "$ps" -NoProfile -NonInteractive -Command '
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $n = New-Object System.Windows.Forms.NotifyIcon
    $n.Icon = [System.Drawing.SystemIcons]::Information
    $n.Visible = $true
    $n.ShowBalloonTip(5000, $env:NOTIFY_TITLE,
      "$env:NOTIFY_SUBTITLE - $env:NOTIFY_BODY",
      [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 5
    $n.Dispose()
  ' >/dev/null 2>&1
}

notify() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin)
      # 1순위: 전용 알림 앱. 클릭하면 호스트 IDE 로 포커스가 간다.
      local app bid
      app="${CLAUDE_NOTIFIER_APP:-$STATE_DIR/ClaudeCodeNotifier.app}"
      if ensure_notifier_app "$app"; then
        bid=$(detect_bundle_id 2>/dev/null) || bid=""
        # 앱은 발송 실패 시 종료 코드 1 을 반환하므로 조용히 실패하지 않는다.
        if "$app/Contents/MacOS/ClaudeCodeNotifier" \
             "$NOTIFY_TITLE" "$NOTIFY_SUBTITLE" "$NOTIFY_BODY" "$bid" >/dev/null 2>&1; then
          return 0
        fi
      fi

      # 폴백: 알림은 뜨지만 클릭 시 스크립트 편집기가 열린다.
      # AppleScript 문자열 보간 대신 argv 로 값을 넘겨 따옴표·백슬래시가
      # 포함된 문구도 안전하게 처리한다.
      # (system attribute 방식은 display notification 인자로 쓰면 -1700 으로 실패한다)
      osascript \
        -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title (item 2 of argv) subtitle (item 3 of argv) sound name "Ping"' \
        -e 'end run' \
        -- "$NOTIFY_BODY" "$NOTIFY_TITLE" "$NOTIFY_SUBTITLE" \
        >/dev/null 2>&1 && return 0
      ;;
    Linux)
      # WSL 이면 Windows 쪽 PowerShell 로 띄운다.
      if grep -qi microsoft /proc/version 2>/dev/null \
         && command -v powershell.exe >/dev/null 2>&1; then
        notify_powershell powershell.exe && return 0
      fi
      if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "$NOTIFY_TITLE" "$NOTIFY_TITLE — $NOTIFY_SUBTITLE" \
          "$NOTIFY_BODY" >/dev/null 2>&1 && return 0
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v powershell.exe >/dev/null 2>&1; then
        notify_powershell powershell.exe && return 0
      fi
      ;;
  esac
  return 1
}

# 어느 경로로도 알리지 못하면 터미널 벨로라도 알린다.
notify || printf '\a' >&2

exit 0
