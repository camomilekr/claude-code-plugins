# git-workflow

Jira 티켓에서 시작해 `architect`(계획) → `developer`(구현) ↔ `reviewer`(검토) 파이프라인으로 개발하는 git 워크플로우 플러그인입니다. 메인 세션은 오케스트레이터로서 직접 구현하지 않고 서브에이전트를 조율합니다.

## 설치

```bash
claude plugin install git-workflow@camomilekr
```

## 구조

```
hooks/                     # SessionStart 훅 — rules/*.md 를 세션 컨텍스트로 주입
├── hooks.json           #   (플러그인은 rules/ 자동 로드를 지원하지 않아 훅이 대신한다)
└── inject-rules.sh
rules/                     # 세션 시작 시 훅으로 주입되는 규칙 — 가볍게 유지
├── core.md    # 파이프라인·티어·계획·루프·커밋·PR 규칙
└── jira.md    # Jira 티켓 조회(공식 Atlassian MCP)·검토 게이트·상태 전환 프로토콜
ref/                       # 자동 주입되지 않음 — 해당 상황에 걸렸을 때만 읽는 참조
├── parallel.md          # 병렬 트랙 개발 (트랙을 나누기로 정한 뒤에만)
├── jira-fetch.md        # 티켓 조회 상세 (본문 보충 조회·이미지 해석 — 조회 시점에만)
├── jira-transitions.md  # 상태 전환 프로토콜 (Transition ID 캐시 — 전환 직전에만)
├── troubleshooting.md   # git·워크트리·훅 증상과 원인
├── testing-traps.md     # 테스트에서 막히는 지점 (jest 기준)
└── incidents.md         # 규약이 이렇게 생긴 이유 (원본 저장소의 사고 기록)
agents/
├── architect.md   # 조사·설계 — docs/plan/에 요구사항 스냅샷 + 계획서 작성 (구현 금지)
├── developer.md   # TDD 구현 — 커밋하지 않고 작업 트리만 남김
└── reviewer.md    # 보안·클린코드·규약·목표 4축 검토 (코드 수정 금지)
```

## 워크플로우 요약

1. **Jira 티켓 조회** — 공식 Atlassian MCP로 본문·댓글·첨부를 수집 (환경변수 계정정보 사용 안 함)
2. **티어 판정** — 작업 크기에 따라 직접 처리 / 가벼운 루프 / 전체 파이프라인
3. **계획 (티어 2)** — `architect`가 요구사항 스냅샷과 80줄 이하 계획서 작성 → 사용자 검토 게이트 → Jira `IN PROGRESS` 전환
4. **구현·검토 루프** — `developer` ↔ `reviewer`를 `blocker`/`major`가 사라질 때까지 반복 (최대 3라운드)
5. **커밋·PR** — 오케스트레이터가 의미 단위로 커밋, PR 생성 후 Jira `IN REVIEW` 전환
