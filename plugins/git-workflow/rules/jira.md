# Jira 연동 규칙

모든 개발의 시작은 Jira 티켓이다. 티켓 조회와 상태 전환은 **공식 Atlassian MCP**(`mcp__claude_ai_Atlassian_Rovo__*`, cloudId `whatap-labs.atlassian.net`)로만 한다. **`JIRA_EMAIL`·`JIRA_API_TOKEN` 같은 환경변수 계정정보를 쓰는 스크립트나 REST 직접 호출은 쓰지 않는다.** MCP가 미연결이면 연결을 안내하고, 사용자가 원하면 티켓 없이 진행하되 상태 전환은 전부 스킵한다.

## 티켓 조회

- 이슈 키는 `[A-Z]+-\d+` 패턴으로 추출한다 — 인자 그대로, URL(`*.atlassian.net/browse/KEY`)에서, 또는 브랜치 이름 `feature/{KEY}(-{설명})`에서. 불명확하면 `AskUserQuestion`으로 확인한다
- `getJiraIssue`(responseContentFormat `markdown`)로 `summary`·`status`·`description`·댓글·링크된 이슈까지 본다. 댓글에 요구사항 변경이나 결정 사항이 남아 있는 경우가 많다
- **`description`이 비어 보이면 본문 없음으로 단정하지 마라.** 본문이 다른 필드에 있는 카드가 있다 — 그 시점에 `ref/jira-fetch.md`를 읽고 보충 조회 절차를 따른다
- **첨부 이미지를 해석해야 하면 해석 전에 `ref/jira-fetch.md`를 읽는다** — 신호 우선순위·이미지 해석 규칙·범위 확장 금지가 거기 있다
- **`architect`에게는 조회한 본문·댓글의 결정 사항·첨부 경로를 원문 그대로 넘긴다.** 요약해서 넘기면 카드에 명시된 해결 방향을 잃는다
- 추측과 사실을 구분해 보고한다 — "이미지로 추정컨대 ~로 보임", "코드 확인 결과 ~임"

## 요약 검토 게이트 (티어 2 필수)

`architect`가 계획서와 함께 남긴 요구사항 스냅샷(`docs/plan/{YYYY-MM-DD}-{KEY}-jira-summary.md`)을 화면에 출력하고 `AskUserQuestion`으로 확인받는다. 요약이 어긋난 채 그 위에 쌓는 계획·코드·PR은 모두 어긋난다.

- **A. 요약 OK — 진행 + Jira 상태 IN PROGRESS 전환** (Recommended. 이미 진행 중 이후 상태면 전환은 자동 skip)
- **B. 수정 필요** — 어긋난 부분을 받아 `architect`에게 `SendMessage`로 돌려보낸 뒤 다시 게이트로
- **C. 보류** — 요약만 남기고 종료

이미지에서 분리해 둔 "별도 의문점"이 있으면 게이트 직전에 함께 물어 범위에 넣을지 확정한다. **A가 사용자 동의의 마지막 지점이다** — 이후 상태 전환에서 추가 프롬프트를 띄우지 않는다. 티어 1은 게이트 없이 착수 시점에 IN PROGRESS 전환만 한다.

## 상태 전환

전환 시점은 둘이다 — **작업 착수 시 `IN PROGRESS`** (티어 2는 게이트 A 선택 직후, 티어 1은 브랜치 생성 직전), **PR 생성 직후 `IN REVIEW`**.

- **전환을 실행하기 직전에 `ref/jira-transitions.md`를 읽는다.** Transition ID 캐시·시퀀스 표·강제 규칙·메시지 포맷·검증 프로젝트 화이트리스트가 거기 있다. **읽지 않고 `getTransitionsForJiraIssue`로 동적 조회하지 마라**
- **전환 실패·skip은 블로커가 아니다.** 사유를 한 줄로 보고하고 본업(계획·PR 생성 등)은 계속 진행한다. 사일런트 종료는 금지다
