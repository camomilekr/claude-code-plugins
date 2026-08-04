# 참조 — Jira 상태 전환 프로토콜

상태 전환을 실행하기 직전에만 읽는다. 전환 시점은 `rules/jira.md`가 정한다 — 착수 시 `IN PROGRESS`, PR 생성 직후 `IN REVIEW`.

- **cloudId**: `whatap-labs.atlassian.net`
- **워크플로우 검증 프로젝트(화이트리스트)**: FRONT, NETWORK, SERVER, LOG, KUBER, WORKSPACE — 이 밖의 프로젝트는 자동 전환을 skip한다 (시퀀스 중간 실패로 카드가 어정쩡한 상태에 남는 사고 방지). **lastVerified**: 2026-05-19

## Transition ID (캐시)

| 키 | Transition ID | from | to |
|---|---|---|---|
| `openToToDo` | **11** | OPEN | TO DO |
| `reopenToToDo` | **161** | Reopen | TO DO |
| `toDoToInProgress` | **21** | TO DO | IN PROGRESS |
| `inProgressToInReview` | **231** | IN PROGRESS | IN REVIEW |

## 시퀀스 표

| 현재 상태 | 종점 `IN PROGRESS` | 종점 `IN REVIEW` |
|---|---|---|
| OPEN | `[11, 21]` | `[11, 21, 231]` |
| Reopen | `[161, 21]` | `[161, 21, 231]` |
| TO DO | `[21]` | `[21, 231]` |
| IN PROGRESS | (이미 종점 — skip) | `[231]` |
| 그 이후·완료·기타 | (자동 전환 안 함) | (자동 전환 안 함) |

## 강제 규칙

1. **인라인 상수만 사용 — `getTransitionsForJiraIssue` 동적 조회 금지.** 동적 조회를 허용하면 응답 기반 분기가 생겨 무한 호출·예측 불가 동작 위험이 있다
2. **시퀀스 길이 고정.** 위 표에서 사전 결정하고 런타임에 늘리지 않는다 (최대 3단계)
3. **동기 호출, 실패 즉시 중단.** 한 단계 실패 시 다음 단계로 진행하지 않는다
4. **자동 재시도 금지.** 실패 원인이 무엇이든 재시도로 해결되지 않는다 — 사용자 수동 조치로 위임한다
5. **사일런트 종료 금지.** 시작·단계·종료·실패·skip 모든 분기에서 한 줄 이상 메시지를 남긴다
6. **전환 실패는 블로커가 아니다.** 경고로만 보고하고 본업(계획·PR 생성 등)은 계속 진행한다. PR이 이미 생성됐다면 URL은 그대로 유지한다

## 사전 체크 (시퀀스 호출 전)

1. `{KEY}`에서 프로젝트 코드(`[A-Z]+` prefix) 추출 → 화이트리스트 밖이면 skip 메시지 후 종료
2. 현재 상태가 시퀀스 표에 있는지 확인 → 없으면 해당 skip 케이스로 종료
3. 통과하면 시퀀스 결정 → 시작 알림 → 단계 호출

## 호출과 메시지

```
mcp__claude_ai_Atlassian_Rovo__transitionJiraIssue(
  cloudId="whatap-labs.atlassian.net", issueIdOrKey="{KEY}", transition={ id: "{stepId}" }
)
```

- 시작: `🔄 Jira {KEY} 상태 전환 시도: {경로} ({총 단계}단계)` / 단계마다: `[{n}/{총}] → {도달 상태}`
- 성공: `✅ Jira {KEY}: {경로} 전환 완료` / 부분 성공: `⚠️ [{k}/{총}] 단계까지 도달. 다음 단계 실패: <에러 요지> — Jira UI에서 수동 마무리`
- skip: 화이트리스트 외 프로젝트 · 이미 종점 이후 · 종료 상태 · 미지원 상태 — 각각 사유를 한 줄로 출력

## 갱신

전환 호출이 ID 불일치로 실패하면 해당 시작 상태의 이슈 1건으로 `getTransitionsForJiraIssue`를 호출해 위 4-row 표를 갱신하고 `lastVerified`를 올린다. 시퀀스 표는 4-row 표의 부분집합이므로 함께 맞춘다.
