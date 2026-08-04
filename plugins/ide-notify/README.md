# IDE Notify

Claude Code가 **작업을 마쳤을 때**, **서브에이전트가 작업을 시작·완료했을 때**, 그리고 **승인·결정을 기다릴 때** 시스템 알림을 보내는 플러그인입니다.

macOS에서는 알림을 클릭하면 **세션을 띄운 터미널/IDE로 포커스가 이동**합니다. (Cursor, VS Code, iTerm2, Terminal, Ghostty, WezTerm 등 자동 감지)

## 설치

```bash
# 마켓플레이스 등록
claude plugin marketplace add camomilekr/claude-code-plugins

# 플러그인 설치
claude plugin install ide-notify@camomilekr
```

마켓플레이스 정의는 [camomilekr/claude-code-plugins](https://github.com/camomilekr/claude-code-plugins)에 있습니다.

설치 후 첫 알림이 발생할 때 macOS 알림 권한 프롬프트가 한 번 뜹니다. **허용**을 눌러 주세요.

## 동작

| 이벤트 | 시점 |
|---|---|
| `Stop` | Claude가 모든 작업을 마쳤을 때 |
| `SubagentStart` | 서브에이전트 하나가 작업을 시작했을 때 (알림에 에이전트 이름 표시) |
| `SubagentStop` | 서브에이전트 하나가 작업을 마쳤을 때 (알림에 에이전트 이름 표시) |
| `Notification` | 승인 요청 / 결정 대기 / 입력 대기 (`permission_prompt`, `elicitation_dialog`, `agent_needs_input`) |

네 훅 모두 `async`라 알림 발송이 세션을 붙잡지 않습니다.

### 서브에이전트 알림 줄이기

`SubagentStart`/`SubagentStop`은 모든 서브에이전트에 대해 울립니다. 에이전트 하나당 시작·완료 두 번이고, 병렬로 여러 개를 띄우면 그만큼 곱해집니다. 시끄럽다면 `hooks/hooks.json`에서 조절하세요.

- **특정 에이전트만** — 해당 항목에 `matcher`를 추가합니다. 에이전트 이름(`agent_type`)에 정규식으로 매칭됩니다.

  ```json
  { "matcher": "^(code-reviewer|Plan)$", "hooks": [ ... ] }
  ```

- **완료 알림만** — `SubagentStart` 항목을 통째로 지웁니다.

## 플랫폼별 지원

| 플랫폼 | 알림 | 클릭 시 IDE 포커스 |
|---|---|---|
| macOS | 전용 앱(UserNotifications) → osascript 폴백 | 지원 |
| Linux | `notify-send` | 미지원 |
| WSL / Windows | PowerShell 토스트 | 미지원 |
| 그 외 / 전부 실패 | 터미널 벨 | — |

## macOS에서 클릭 포커스가 동작하는 원리

macOS 알림은 **클릭 대상을 지정할 수 없고**, "알림을 보낸 앱"이 활성화됩니다. `osascript`로 보내면 발신자가 **스크립트 편집기**가 되어 클릭 시 그 앱이 열립니다.

그래서 이 플러그인은 `UserNotifications` 프레임워크를 쓰는 작은 Swift 앱(`ClaudeCodeNotifier.app`)을 빌드해 알림 발신자로 사용합니다. 이 앱이 클릭을 받아 대상 IDE를 `NSWorkspace`로 활성화합니다.

앱은 `~/.claude/ide-notify/ClaudeCodeNotifier.app`에 빌드되며, **없으면 첫 알림 때 자동으로 한 번 빌드**됩니다 (Xcode Command Line Tools 필요). 빌드할 수 없으면 `osascript`로 폴백해 알림 자체는 계속 동작합니다.

수동 빌드:

```bash
bash ~/.claude/plugins/cache/camomilekr/ide-notify/1.0.1/scripts/build-notifier.sh
```

경로의 `camomilekr`는 마켓플레이스 이름, `1.0.1`은 플러그인 버전이라 환경에 따라 다릅니다. 확인하려면:

```bash
ls -d ~/.claude/plugins/cache/*/ide-notify/*/
```

### 시도했다가 안 된 방법 (기록)

같은 문제를 겪는 분을 위해 남깁니다. 모두 macOS 26.5에서 실측했습니다.

- **`tell application id "..." to display notification`** — 원리적으로 불가능합니다. `display notification`은 StandardAdditions 명령인데 macOS 10.14부터 스크립팅 추가 기능이 임의 앱에 로드되지 않습니다. 대상 앱이 이 명령을 구현하지 않으면(Cursor·Terminal 모두 `sdef` 없음) 명령은 osascript 안에서 실행되고 발신자는 그대로입니다. 종료 코드는 0이라 성공처럼 보입니다.
- **`terminal-notifier`** — `otool`/`nm` 확인 결과 `NSUserNotification`만 링크하고 `UserNotifications.framework`를 쓰지 않습니다. 이 API는 최신 macOS에서 제거돼 알림이 뜨지 않습니다. **그러면서 종료 코드 0을 반환**하므로, 이 스크립트에서 우선 사용하면 알림이 안 뜨는데 성공으로 처리되는 함정이 있습니다. `alerter` 등 파생 도구도 같은 API를 씁니다.
- **`osacompile` AppleScript applet** — 번들 바이너리를 직접 실행해도 `open`으로 띄워도 `on run`이 실행되지 않았습니다.

## 설정 (환경변수)

| 변수 | 용도 |
|---|---|
| `CLAUDE_NOTIFY_BUNDLE_ID` | 클릭 시 포커스할 앱의 번들 ID를 강제 지정. 자동 감지가 틀릴 때 사용 |
| `CLAUDE_NOTIFIER_APP` | 전용 알림 앱 경로 재정의 |
| `CLAUDE_NOTIFY_DEBUG=1` | 진단 로그를 `~/.claude/ide-notify/notifier.log`에 기록 |
| `CLAUDE_NOTIFY_NO_BUILD=1` | 전용 앱 자동 빌드를 끄고 `osascript`만 사용 |

호스트 앱 번들 ID는 4단계로 감지합니다: `CLAUDE_NOTIFY_BUNDLE_ID` → `__CFBundleIdentifier` → 프로세스 조상의 `.app` 번들 → `TERM_PROGRAM` 매핑.

## 문제 해결

**알림이 안 뜬다**

```bash
echo '{"message":"test"}' | CLAUDE_NOTIFY_DEBUG=1 \
  ~/.claude/plugins/cache/camomilekr/ide-notify/1.0.1/scripts/notify.sh input
cat ~/.claude/ide-notify/notifier.log
```

`posted OK`가 있으면 전용 앱으로 발송된 것입니다. 로그가 없으면 `osascript` 폴백을 탄 것이고, 터미널 벨(`\a`)만 울리면 모든 경로가 실패한 것입니다.

**클릭해도 스크립트 편집기가 열린다** — 전용 앱 빌드에 실패해 `osascript`로 폴백 중입니다. `~/.claude/ide-notify/.build-failed` 스탬프를 지우고 `build-notifier.sh`를 직접 실행해 에러를 확인하세요.

**알림 권한이 거부됐다** — 시스템 설정 → 알림 → `Claude Code`에서 허용하세요. 앱을 재빌드하면 ad-hoc 서명이 바뀌어 권한을 다시 물어볼 수 있습니다.

## 구조

```
.claude-plugin/
  plugin.json          플러그인 매니페스트
hooks/
  hooks.json           Stop / SubagentStart / SubagentStop / Notification 훅 등록
scripts/
  notify.sh            알림 발송 (플랫폼 분기 + 폴백)
  build-notifier.sh    ClaudeCodeNotifier.app 빌드
src/
  ClaudeCodeNotifier.swift   UserNotifications 기반 알림 앱
```

## 라이선스

MIT
