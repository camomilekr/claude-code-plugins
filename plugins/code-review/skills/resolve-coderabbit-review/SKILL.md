---
name: resolve-coderabbit-review
description: |
  CodeRabbit PR 리뷰 코멘트를 분석하고 처리합니다. 리뷰 코멘트를 조회하여 지적의
  적절성을 판단하고, 타당한 지적은 코드를 수정·커밋한 뒤 GitHub 댓글로 응답하며,
  부적절한 지적은 근거를 들어 반박합니다.
  This skill should be used when resolving CodeRabbit review comments on a GitHub PR.
  트리거 조건:
  - 키워드: "CodeRabbit", "coderabbit", "리뷰 확인", "PR 리뷰", "review comments"
  - PR 번호 또는 URL과 함께 사용
  주요 기능: 리뷰 코멘트 조회, 피드백 분석, 코드 수정, 응답 작성, 스레드 정리
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - Agent
  - Task
  - AskUserQuestion
argument-hint: "[pr_number]"
---

# CodeRabbit PR Review Analyzer

CodeRabbit이 남긴 PR 리뷰 코멘트를 **분석하고 적절성을 판단**하는 Skill입니다.

> **시작 전 반드시 [WORKFLOW.md](WORKFLOW.md)를 읽으세요.** 이 문서는 개요이고, 실행에 필요한 단계별 지침·프롬프트·안전장치는 모두 WORKFLOW.md에 있습니다.

## 핵심 동작

```
코멘트 조회 → 이전 라운드 스레드 정리 → 각 코멘트 분석 (적절성 판단)
    ├─ ✅ appropriate    → 요약 → 코드 수정 → 타입 검증 → Commit & Push → 수정 내용 댓글
    └─ ⚠️ needs_response → GitHub 반박/보완 댓글 작성
```

**중요**:

- 판정은 **2가지**뿐입니다 — `appropriate`(수정) / `needs_response`(응답). "부분적으로 맞음"도 `needs_response`로 분류합니다.
- 코드를 수정한 경우, 지적의 타당성과 수정 내용을 정리한 댓글을 **반드시** 작성
- 수정 대상은 사용자에게 보여주고 확인 후 진행
- 타입 검증 통과 후 자동 커밋 & 푸시 (**단, PR head 브랜치와 현재 브랜치가 같을 때만**)
- 스레드 resolve는 이번 실행이 아니라 **다음 실행 시점**에, CodeRabbit이 수정을 수긍한 경우에만 수행

## 사용법

```bash
# PR 리뷰 코멘트 분석
/resolve-coderabbit-review 5665

# 현재 브랜치 PR 자동 감지
/resolve-coderabbit-review
```

## 요구 사항

| 도구 | 용도 |
|------|------|
| `gh` (인증 완료) | PR 조회, GraphQL, 댓글 작성 |
| `jq` | 스크립트의 JSON 가공 |
| `perl` | 코멘트 본문에서 불필요한 섹션 제거 |

`gh auth status`로 인증 상태를 먼저 확인하세요. 코드 수정 및 푸시에는 대상 저장소 쓰기 권한이 필요합니다.

## 분석 기준

각 CodeRabbit 코멘트에 대해:

1. **해당 파일/라인의 코드 읽기**
2. **CodeRabbit 지적 내용 검토**
3. **판단**:
   - ✅ **appropriate**: 지적이 100% 타당하고 수정이 필요함 → 코드 수정 후 타당성 + 수정 내용 댓글 작성
   - ⚠️ **needs_response**: 오해, 의도적 설계, 부분적으로만 맞음, 추가 설명 필요 → GitHub 반박/보완 댓글 작성

## 결과 출력 형식

```markdown
## CodeRabbit Review Analysis for PR #5665

**Total Comments:** 5 | ✅ Appropriate: 4 | ⚠️ Needs Response: 1

### ✅ 적절한 지적 (수정 후 댓글 작성 예정)

**1. WORKFLOW.md:207 - export 방식 불일치** 🔴 Critical
- 요약: default export와 named import가 혼용됨
- 분석: 실제로 템플릿 간 불일치로 컴파일 에러 발생 가능
- 권장: named export로 통일 필요

---

### ⚠️ 응답 필요 (GitHub 댓글 작성 예정)

**2. preview.css:36 - CSS 변수 미정의** 🔴 Critical
- CodeRabbit 지적: --bg-color, --bg-font-color 미정의
- 분석: 실제로 Storybook 테마 데코레이터에서 동적 주입됨
- 응답 이유: 변수는 ThemeDecorator에서 런타임에 설정됨
- 작성할 GitHub 댓글: "CSS 변수는 ThemeDecorator가 런타임에 주입합니다..."
```

## 심각도 분류

CodeRabbit이 코멘트 본문에 `_🔴 Critical_` 형태로 심각도를 표기합니다. **본문에 표기가 있으면 그대로 사용하고**, 없을 때만 아래 기준으로 직접 분류합니다.

| 아이콘 | 심각도 | 설명 |
|--------|--------|------|
| 🔴 | Critical | 즉시 수정 필요 (보안, 런타임 에러) |
| 🟠 | Major | 중요 수정 권장 (로직 오류, 타입 안전성) |
| 🟡 | Minor | 개선 제안 (코드 스타일, 가독성) |

## CodeRabbit 코멘트 형식

사용자 ID: `coderabbitai[bot]`

```markdown
_⚠️ Potential issue_ | _🔴 Critical_

**제목/요약**

상세 설명...

<details>
<summary>🤖 Prompt for AI Agents</summary>
AI 에이전트용 수정 지침...
</details>
```

## 코멘트 수집

**반드시 스크립트를 사용하세요** (resolved 코멘트 자동 필터링):

```bash
# CodeRabbit 코멘트 조회 (resolved 제외)
${CLAUDE_PLUGIN_ROOT}/skills/resolve-coderabbit-review/scripts/fetch-coderabbit-comments.sh {pr_number}
```

출력에는 기본 필드 외에 다음이 포함됩니다:

| 필드 | 의미 |
|------|------|
| `is_outdated`, `original_line` | 이미 변경된 코드 위치에 대한 지적 여부와 원 위치 |
| `reply_count`, `last_reply_author` | 이미 답변한 스레드 구분 — 중복 반박 방지 |
| `thread_id` | 스레드 resolve 처리용 |
| `fix_marker` | 이전 실행이 남긴 수정 완료 마커 (커밋 해시 포함) |
| `coderabbit_reply_after_fix` | 마커 이후 CodeRabbit이 남긴 답글 — 승인/재지적 판정용 |

**수집 범위**: 코드 라인에 달린 리뷰 스레드만 수집합니다. PR 본문의 Walkthrough·Summary 코멘트와 `<details>`로 접힌 Nitpick 묶음은 **포함되지 않습니다.**

자세한 활용법은 [WORKFLOW.md](WORKFLOW.md) 참조.

### 응답 작성

반박 댓글과 수정 완료 댓글 모두 동일한 API를 사용합니다:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies \
  --method POST -f body="반박 내용 또는 타당성 인정 + 수정 내용 정리"
```

수정 완료 댓글에는 **반드시 마커를 포함**해야 합니다 (다음 실행의 스레드 정리에 사용):

```
<!-- resolve-coderabbit-review:fixed commit={commit_hash} -->
```

## 안전장치

| 항목 | 규칙 |
|------|------|
| 브랜치 검증 | PR head 브랜치 ≠ 현재 브랜치면 코드 수정·커밋·푸시 단계를 **차단** |
| 타입 검증 | whatap-front 저장소는 모듈 스코프 tsc, 그 외에는 프로젝트 typecheck 스크립트 자동 탐지. 실패해도 커밋을 막지 않음 |
| 중복 방지 | `reply_count > 0`이고 마지막 답글이 사람이면 같은 논지의 반박을 다시 달지 않음 |
| resolve | 수정+커밋+댓글이 끝나고 CodeRabbit이 **수긍한** 스레드만 다음 실행에서 resolve. 애매하면 열어둠 |

## 워크플로우 단계

자세한 단계별 지침은 [WORKFLOW.md](WORKFLOW.md)를 참조하세요.

Subagent 병렬 처리 방식의 토큰 절약 측정 근거는 [BENCHMARK.md](BENCHMARK.md)에 있습니다.
