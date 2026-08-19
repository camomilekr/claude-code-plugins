# spec-driven-workflow

스펙 주도 단방향 개발 파이프라인 플러그인이다.

```
architect(계획) → spec-writer(완료 기준을 실패하는 테스트로 고정) → 스펙 커밋
  → developer(스펙을 green으로) → G1(verify·테스트) → G2(스펙 무결성) → G3(검토 1회) → 커밋·PR
```

`git-workflow` 플러그인(architect → developer ↔ reviewer 왕복 루프)의 대안 구조를 검증하기 위한 비교 실험용 플러그인이다. 같은 작업을 두 플러그인으로 각각 수행해 시간·토큰·비용·결함 검출을 비교하는 것이 목적이므로, **git-workflow는 수정하지 않고 0.2.9에서 대조군으로 동결한다.** 두 플러그인의 규칙 주입이 겹치므로 **실험 중에는 한 세션에 하나만 활성화한다.**

## 왜 만드는가 (한 줄 요약)

실험 실측에서 git-workflow 비용 격차의 몸통이 "오케스트레이터 + 리뷰 왕복 두 층"과 "리뷰 대기 중 컨텍스트 재생성"으로 확인됐고, 리뷰 루프의 결함 검출은 최신 실험에서 단순 절차와 구분되지 않았다. 이 플러그인은 그 두 층을 걷어내고, 검증을 (1) 결정론적 게이트 (2) 구현 전에 고정하는 스펙 테스트 (3) 새 컨텍스트 1회 검토로 재배치한다.

## 사용하는 프로젝트가 준비할 것

게이트는 프로젝트의 검증 명령을 모른다. 대상 저장소의 `.claude/spec-workflow.json`에 명령을 선언한다 (CI workflow 파일과 같은 패턴이다):

```json
{
  "commands": {
    "verify": "npm run verify",
    "test": "npm test -- {paths}",
    "e2e": "npm run test:e2e"
  },
  "timeoutSeconds": 300
}
```

`verify`·`test`는 필수, `e2e`와 `mutation`은 선택. `test`의 `{paths}` 자리에 게이트가 대상 경로를 치환한다(경로 지정 강제). `mutation`(예: Stryker)을 선언하면 G1이 함께 실행한다 — 스펙 표본에만 과적합한 구현을 기계로 잡는 선택 게이트이며, 타임아웃은 `mutationTimeoutSeconds`로 따로 준다. **선언이 없으면 게이트는 침묵 통과가 아니라 명시적으로 실패하고**, 오케스트레이터가 온보딩 절차(`rules/core.md`)로 설정 생성을 안내한다. 특정 러너·언어를 가정하지 않는다 — 게이트가 보는 것은 선언된 명령의 exit code뿐이다.

## 문서

- **`docs/design.md`** — 설계서 정본. 근거 실측, 파이프라인, 에이전트·게이트 명세, 실험 설계까지 전부 여기에 있다
- **`docs/spec-test-gap.md`** — 스펙과 스펙 테스트는 동치가 아니다(테스트는 스펙의 유한 표본이다)라는 간극의 해부와, 간극 성분별 보완 장치의 근거. **green은 요구사항 충족의 증명이 아니다**
- **`docs/spec-driller.md`** — spec-driller 스킬의 설계 근거. 요구사항 문서의 모순·엣지케이스·누락을 질문으로 만들어 사용자 결정을 받아 문서를 보강하는 대화형 스킬 — 간극의 위층(요구사항 자체)을 덮는다. 구현은 `skills/spec-driller/`
- **`docs/decisions.md`** — 설계서 12절 미해결 질문과 spec-test-gap 개선 후보를 구현 시점에 어떻게 결정했는지의 기록

## 구성

| 경로 | 내용 |
|---|---|
| `rules/core.md` | 파이프라인·티어·오케스트레이터 규칙. SessionStart 훅이 세션에 주입한다 |
| `agents/` | `architect` · `spec-writer` · `developer` · `reviewer` 정의 |
| `scripts/gate-verify.sh` | G1 — verify·테스트·e2e를 한 호출로 묶어 실행, exit code 판정 |
| `scripts/spec-guard.sh` | G2 — 스펙 무변경 검사 + 전부 green 검사 |
| `scripts/spec-commit.sh` | 스펙 커밋 — 요구사항 추적 검사(계획서의 모든 `[테스트]` 항목이 스펙에 매핑됐는가) 후 매니페스트 등재 파일만 커밋하고 해시를 매니페스트에 기록 |
| `hooks/` | 규칙 주입 훅 (`inject-rules.sh`) |
| `skills/spec-driller/` | 요구사항 드릴링 스킬 — 탐침으로 모순·엣지케이스·누락을 질문으로 만들고 사용자 결정을 확정 조항·미결 항목으로 문서에 기입한다. 티어 2 architect 호출 전 권장(의무 아님), 파이프라인 밖 단독 사용 가능 |
| `ref/probes.md` | 탐침 정본 — spec-driller(요구사항 레벨, 사람에게 질문)와 spec-writer(스펙 레벨, 자문)가 공유한다. PR 시점 함정 이관의 영구 자리 |

## git-workflow에서 계승한 실증 레버

- 테스트 실행 제약: 경로 지정 강제 + 300초 상한 (시간 −62%·토큰 −65% 실측)
- 검증 게이트를 한 번의 호출로 묶기 (요청 수 절감)
- 전용 워크트리 강제 (0.2.8) — G2·G3가 보는 diff의 기준점 보호
- 함정의 프롬프트 이관 (0.2.9) — 단계 간 통신이 파일인 이 설계에서도 함정만은 프롬프트에 싣는다
- PR 시점 함정 이관 (0.2.9), 티어 판정 조건, dev-loop 인계 기록
