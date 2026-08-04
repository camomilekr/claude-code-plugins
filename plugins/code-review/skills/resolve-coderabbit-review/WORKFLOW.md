# CodeRabbit Review Analysis Workflow

## 핵심 원칙

**CodeRabbit 코멘트를 분석하고 적절성을 판단한다.**

- ✅ 적절한 지적 → 코드 수정 → 커밋 후, 지적의 타당성과 수정 내용을 정리한 댓글 작성 (**필수**)
- ⚠️ 응답 필요 → GitHub 반박/보완 댓글 작성 + 사용자에게 요약/이유 표시

**중요**: 처리한 모든 코멘트에 댓글을 남긴다. 적절한 지적은 수정 완료 후 수정 내용 댓글(단계 9), 반박이 필요한 지적은 반박 댓글(단계 5).

---

## 단계 1: 입력 파싱 및 PR 상태 검증 (메인 에이전트)

### PR 번호 추출

```bash
# 인자로 PR 번호가 주어진 경우
PR_NUMBER=$ARGUMENTS

# 인자 없이 실행 시 현재 브랜치의 PR 자동 감지
gh pr view --json number --jq '.number'
```

### Repository 정보

```bash
gh repo view --json nameWithOwner --jq '.nameWithOwner'
```

### PR 상태 검증

**중요**: merged/closed PR은 분석은 가능하지만 댓글 작성이 불가능하거나 무의미합니다.

```bash
# PR 상태 확인
gh pr view {pr_number} --json state,merged --jq '{state, merged}'
```

| PR 상태 | 분석 | 댓글 작성 | 동작 |
|---------|------|----------|------|
| `OPEN` | ✅ | ✅ | 정상 진행 |
| `MERGED` | ✅ | ❌ 불가 | 경고 출력 후 분석만 진행 |
| `CLOSED` | ✅ | ⚠️ 무의미 | 경고 출력 후 분석만 진행 |

**참고**: `fetch-coderabbit-comments.sh` 스크립트가 자동으로 PR 상태를 확인하고 경고를 출력합니다.

---

## 단계 2: CodeRabbit 코멘트 수집 (메인 에이전트)

### 스크립트 사용

토큰 절약을 위해 전용 스크립트를 사용합니다. 스크립트는 body에서 불필요한 섹션을 자동 제거합니다:

- `🧩 Analysis chain` - CodeRabbit 내부 분석 로그
- `🤖 Prompt for AI Agents` - AI 에이전트용 지침
- HTML 주석

```bash
# 스크립트 실행
${CLAUDE_PLUGIN_ROOT}/skills/resolve-coderabbit-review/scripts/fetch-coderabbit-comments.sh {pr_number}

# 출력: JSON 배열
# [
#   {
#     "id": 12345,
#     "path": "파일경로",
#     "line": 42,
#     "body": "가공된 코멘트 내용 (불필요한 섹션 제거됨)",
#     "created_at": "2026-01-09T09:41:42Z",
#     "thread_id": "PRRT_kwDO...",
#     "is_outdated": false,
#     "original_line": 42,
#     "start_line": null,
#     "reply_count": 0,
#     "last_reply_author": null
#   },
#   ...
# ]
```

**추가 필드 활용**:

- `is_outdated: true` → 코드가 이미 변경된 위치에 대한 지적. 현재 코드 기준으로 여전히 유효한지 먼저 확인 (원 위치는 `original_line` 참고)
- `reply_count > 0` + `last_reply_author`가 CodeRabbit이 아닌 사용자 → 이미 답변한 스레드일 수 있으므로 중복 반박 주의
- `thread_id` → 수정 완료 후 스레드 resolve 처리에 사용 가능 (GraphQL `resolveReviewThread` mutation)

---

## 단계 3: 코멘트별 분석

**이 단계가 핵심입니다.**

### 처리 방식 선택

**고유 파일 수**에 따라 처리 방식을 선택합니다:

| 고유 파일 수 | 처리 방식               | 이유                         |
| ------------ | ----------------------- | ---------------------------- |
| **≤ 3개**    | 메인 에이전트 순차 처리 | 토큰 효율적 (파일 읽기 공유) |
| **> 3개**    | Subagent 병렬 처리      | 속도 우선                    |

**중요**: 같은 파일에 대한 코멘트는 반드시 하나의 처리 단위로 묶습니다.
예: `DeviceTable.tsx`에 코멘트 3개 → 하나의 Subagent가 파일을 한 번만 읽고 3개를 모두 분석.
이렇게 하면 파일 중복 읽기를 방지하여 토큰을 절약합니다.

---

### 방식 A: 메인 에이전트 순차 처리 (고유 파일 ≤ 3개)

메인 에이전트가 직접 각 코멘트를 순차적으로 분석합니다.

**장점**: 파일 읽기를 공유하여 토큰 절약

```
각 코멘트에 대해:
1. 해당 파일의 코드 읽기 (Read 도구)
2. CodeRabbit 지적 내용 검토
3. 적절성 판단
4. 반박 필요 시 반박 내용 작성
```

---

### 방식 B: Subagent 병렬 처리 (고유 파일 > 3개)

**파일 단위로 그룹핑**한 뒤, 그룹의 코멘트 수에 따라 프롬프트를 분기하여 Subagent를 병렬 실행합니다.

**장점**: 같은 파일의 코멘트를 묶어 파일 중복 읽기 방지 + 병렬 속도

#### 프롬프트 분기 로직

```
파일별로 코멘트를 그룹핑한 뒤, 각 그룹에 대해:
  if 그룹 코멘트 수 == 1:
    → 단일 코멘트 프롬프트 사용 (B-1)
  else:  # 그룹 코멘트 수 ≥ 2
    → 파일 그룹 프롬프트 사용 (B-2)

Task(subagent_type="code-reviewer", prompt=...)  # 그룹별 1 Subagent, 병렬 실행
```

> **분기 이유**: 파일에 코멘트가 1개뿐인 그룹은 그룹 프롬프트의 JSON 배열 + 추가 지침이 오버헤드만 늘리고 절약 효과가 없습니다(평균 -68토큰 손해). 단일 코멘트 프롬프트로 폴백하면 손해를 0으로 만들 수 있습니다. 같은 파일에 코멘트가 2개 이상 모인 그룹에서만 그룹핑 효과(파일을 1번만 읽음)가 발생합니다.

#### B-1. 단일 코멘트 프롬프트 (그룹 코멘트 수 = 1)

```
CodeRabbit 리뷰 코멘트를 분석하고 적절성을 판단하세요.

코멘트 정보:
- ID: {id}
- 파일: {path}
- 라인: {line}
- 내용: {body}

작업:
1. 해당 파일의 코드 읽기 (Read 도구로 {path} 파일의 line {line} 주변 읽기)
2. CodeRabbit 지적 내용과 실제 코드 비교
3. 적절성 판단:
   - ✅ appropriate: 지적이 타당하고 코드 수정이 필요함
   - ❌ needs_response: 오해, 의도적 설계, 또는 추가 설명이 필요함
4. needs_response인 경우 응답 내용 작성 (**반드시 한국어로**)

반환 형식 (JSON):
{
  "id": {id},
  "path": "{path}",
  "line": {line},
  "severity": "critical|major|minor",
  "summary": "CodeRabbit 지적 요약 (1줄)",
  "verdict": "appropriate|needs_response",
  "analysis": "분석 내용 (2-3줄)",
  "response": "응답 내용 또는 null"
}
```

#### B-2. 파일 그룹 프롬프트 (그룹 코멘트 수 ≥ 2)

```
CodeRabbit 리뷰 코멘트를 분석하고 적절성을 판단하세요.

대상 파일: {path}

코멘트 목록:
[
  { "id": {id_1}, "line": {line_1}, "body": "{body_1}" },
  { "id": {id_2}, "line": {line_2}, "body": "{body_2}" },
  ...
]

작업:
1. 해당 파일의 코드 읽기 (Read 도구로 {path} 파일 읽기 — 한 번만 읽고 모든 코멘트에 활용)
2. 각 코멘트에 대해:
   a. CodeRabbit 지적 내용과 실제 코드 비교
   b. 적절성 판단:
      - ✅ appropriate: 지적이 타당하고 코드 수정이 필요함
      - ❌ needs_response: 오해, 의도적 설계, 또는 추가 설명이 필요함
   c. needs_response인 경우 응답 내용 작성 (**반드시 한국어로**)

반환 형식 (JSON 배열):
[
  {
    "id": {id_1},
    "path": "{path}",
    "line": {line_1},
    "severity": "critical|major|minor",
    "summary": "CodeRabbit 지적 요약 (1줄)",
    "verdict": "appropriate|needs_response",
    "analysis": "분석 내용 (2-3줄)",
    "response": "응답 내용 또는 null"
  },
  ...
]
```

---

### 분석 기준 (공통)

각 코멘트에 대해:

1. **해당 파일의 코드 읽기** (Read 도구 사용)

   - CodeRabbit이 지적한 파일과 라인을 읽어 문맥 파악

2. **지적 내용 검토**

   - CodeRabbit이 무엇을 지적했는지 이해
   - 제안된 수정 사항 확인

3. **적절성 판단 (2가지)**

   - ✅ **appropriate**: 지적이 타당하고 코드 수정이 필요함 → 코드 수정 후 수정 내용 댓글 작성 (단계 9)
   - ❌ **needs_response**: 오해, 의도적 설계, 또는 추가 설명 필요 → GitHub 반박 댓글 작성 (단계 5)

4. **needs_response인 경우 응답 내용 작성**
   - 왜 CodeRabbit의 지적이 틀렸거나 맥락이 필요한지 설명
   - 코드의 의도나 숨겨진 문맥 제시

### Verdict 판단 기준

| Verdict | 조건 | GitHub 댓글 | 예시 |
|---------|------|------------|------|
| `appropriate` | 지적이 **100% 타당**하고 코드 수정이 필요함 | ✅ 수정 완료 후 작성 (타당성 + 수정 내용) | 실제 버그, 타입 오류, 컴파일 에러 |
| `needs_response` | **오해**, **의도적 설계**, 또는 **추가 설명** 필요 | ✅ 반박/보완 댓글 작성 | 동적 주입, 런타임 처리, 트레이드오프 설명 |

#### 판단 플로우

```
CodeRabbit 지적이 100% 타당한가?
    │
    ├─ YES → appropriate (코드 수정 → 수정 완료 후 댓글 작성)
    │
    └─ NO → needs_response (반박 댓글 작성)
            - 완전히 틀림 (반박)
            - 부분적으로 맞음 (보완 설명)
            - 의도적 설계 (맥락 설명)
```

### 반환 형식 (JSON)

```json
[
  {
    "id": 12345,
    "path": "파일경로",
    "line": 42,
    "severity": "critical|major|minor",
    "summary": "CodeRabbit 지적 요약",
    "verdict": "appropriate|needs_response",
    "analysis": "분석 내용",
    "response": "응답이 필요한 경우에만 작성 (없으면 null)"
  }
]
```

---

## 단계 4: 분석 결과 표시 (메인 에이전트)

사용자에게 분석 결과를 보여줍니다.

### 출력 형식

```markdown
## CodeRabbit Review Analysis for PR #{pr_number}

**Total Comments:** {total} | ✅ Appropriate: {appropriate_count} | ⚠️ Needs Response: {response_count}

---

### ✅ 적절한 지적 (수정 후 댓글 작성 예정)

**1. {path}:{line} - {title}** {severity_icon}

- 요약: {summary}
- 분석: {analysis}
- 권장: {recommendation}

---

### ⚠️ 응답 필요 (GitHub 댓글 작성 예정)

**2. {path}:{line} - {title}** {severity_icon}

- CodeRabbit 지적: {summary}
- 분석: {analysis}
- 응답 이유: {response_reason}
- 작성할 GitHub 댓글: "{response_content}"
```

---

## 단계 5: GitHub 반박 댓글 작성 (needs_response)

### 댓글 작성 조건

**이 단계에서는 needs_response verdict인 코멘트에만 GitHub 댓글을 작성합니다.**

appropriate verdict의 댓글은 코드 수정과 커밋·푸시가 끝난 뒤 단계 9에서 작성합니다 (수정 내용을 정리해야 하므로 이 시점에는 작성하지 않음).

### 사용자 확인

```
AskUserQuestion:
"다음 코멘트에 응답 댓글을 작성하시겠습니까?"

응답 대상:
1. {path}:{line} - "{response_content}"
2. ...

옵션:
- [작성] 모든 응답 댓글 작성
- [선택] 일부만 선택
- [취소] 댓글 작성 안 함
```

### GitHub API 호출

```bash
# 특정 코멘트에 답장
gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies \
  --method POST \
  -f body="@coderabbitai {response_content}"
```

### 댓글 형식

**반드시 한국어로 작성합니다.**

```markdown
@coderabbitai 리뷰 감사합니다!

{응답 내용 — 한국어로 작성}

{필요시 코드 참조나 설명 추가}
```

---

## 단계 6: 적절한 지적 코드 수정

### 수정 대상 확인

`appropriate` verdict인 코멘트를 심각도별로 분류합니다:

- 🔴 **Critical / 🟠 Major**: 수정 권장 목록에 포함
- 🟡 **Minor**: 참고용으로 별도 표시 (선택적)

### 사용자 확인

```
AskUserQuestion:
"다음 CodeRabbit 지적에 대해 코드를 수정하시겠습니까?"

🔴🟠 수정 권장:
1. {path}:{line} - {summary} 🔴
2. {path}:{line} - {summary} 🟠
...

🟡 참고 (Minor):
3. {path}:{line} - {summary}

옵션:
- [모두 수정] 권장 항목 모두 수정
- [선택 수정] 일부만 선택
- [수정 안함] 스킵
```

### 코드 수정 실행

사용자가 선택한 항목에 대해:

1. 해당 파일 읽기 (Read 도구)
2. CodeRabbit 제안에 따라 코드 수정 (Edit 도구)
3. 수정 결과 사용자에게 표시

### 주의사항

- 복잡한 수정은 사용자에게 설명 후 진행
- 수정 전후 diff를 보여줌
- 에러 발생 시 롤백 안내

---

## 단계 7: 수정 코드 타입 검증

### 조건

단계 6에서 코드 수정이 발생한 `.ts`/`.tsx` 파일이 있는 경우에만 실행됩니다.
비-TypeScript 파일(`.md`, `.sh`, `.css` 등)만 수정된 경우 이 단계를 건너뜁니다.

### 검증 방식

수정된 파일의 **상위 모듈 디렉토리**를 대상으로 임시 tsconfig를 생성하여 스코프된 타입 체크를 수행합니다.
전체 프로젝트 tsc가 아닌 디렉토리 단위 체크로, 수 초 내에 완료됩니다.

### 검증 절차 (의사코드 — Claude가 참고하여 Bash 도구로 실행)

**Step 1**: 수정된 `.ts`/`.tsx` 파일의 상위 모듈 디렉토리를 추출합니다.

디렉토리 추출 규칙:
- FSD 구조 (`src/fsd/{domain}/{layer}/{module}/...`) → `src/fsd/{domain}/{layer}/{module}/**/*`
- Service 등 기타 (`src/service/{category}/...`) → `src/service/{category}/**/*`
- `apps/whatap-front/` 외부 파일 (packages/ 등) → 검증 대상에서 제외

**Step 2**: 임시 tsconfig 생성

```json
// apps/whatap-front/tsconfig.verify.json
{
  "extends": "./tsconfig.app.json",
  "include": ["src/fsd/networkManagement/4_features/DeviceList/**/*", ...],
  "references": []
}
```

**Step 3**: 스코프된 타입 체크 실행

```bash
node_modules/.pnpm/node_modules/.bin/tsc --noEmit --pretty false \
  -p apps/whatap-front/tsconfig.verify.json 2>&1
```

**Step 4**: 임시 tsconfig 삭제

```bash
rm -f apps/whatap-front/tsconfig.verify.json
```

**폴백**: tsc 실행이 실패(OOM, 경로 에러 등)하면 `⚠️ 타입 검증 스킵 (실행 실패)` 를 표시하고 단계 8로 진행합니다. 검증 실패가 커밋을 차단하지 않습니다.

**한계**: 이 방식은 모듈 디렉토리 내부의 타입만 검증합니다. cross-module 의존성(다른 모듈에서 import하는 타입이 깨진 경우)은 감지하지 못할 수 있습니다.

### 결과 처리

| 결과 | 동작 |
|------|------|
| 에러 없음 | `✅ 타입 검증 통과` 표시 후 단계 8로 진행 |
| 수정 파일에 에러 | 에러 내용 표시 → 수정 시도 → 재검증 |
| 기존 에러만 (수정 파일 외) | `⚠️ 기존 타입 에러 {n}건 (수정과 무관)` 표시 후 진행 |

**중요**: 검증 실패 시 에러가 수정된 파일에서 발생한 것인지 확인합니다.
수정과 무관한 기존 에러는 무시하고 진행합니다.

---

## 단계 8: 자동 Commit & Push

### 조건

단계 6에서 코드 수정이 발생하고, 단계 7 타입 검증을 통과했거나 스킵된 경우에 실행됩니다.

### 자동 Commit & Push (사용자 확인 불필요)

코드 수정 완료 후 **사용자 확인 없이 바로 커밋하고 푸시**합니다.

```bash
# 변경된 파일 스테이징
git add {modified_files}

# 커밋 메시지 형식 (변경 유형에 따라 적절한 타입 선택)
# - fix: 버그 수정, 타입 오류, 런타임 에러, 잘못된 로직 수정
# - refactor: 코드 구조 개선, 중복 제거, 가독성 향상 (기능 변경 없음)
# - style: 포맷팅, 세미콜론, 공백, 코드 스타일 (기능 변경 없음)
# - perf: 성능 개선, 최적화
# - docs: 문서, 주석, README 수정
# - chore: 빌드 설정, 의존성, 도구 설정 변경
# - test: 테스트 추가, 수정, 테스트 관련 변경
# - feat: 새로운 기능 추가 (리뷰 피드백에서는 드묾)
# - build: 빌드 시스템, 외부 의존성 변경 (webpack, vite 등)
# - ci: CI 설정 파일 및 스크립트 변경
# - revert: 이전 커밋 되돌리기

git commit -m "{type}: address CodeRabbit review feedback

- {summary1}
- {summary2}

Co-Authored-By: Claude <noreply@anthropic.com>"

# 현재 브랜치를 원격에 푸시
git push origin HEAD
```

**푸시 실패 시**: 원격에 새 커밋이 있으면 `git pull --rebase` 후 재시도합니다. 그래도 실패하면 커밋 상태를 유지한 채 사용자에게 알리고, 단계 9의 수정 완료 댓글에는 푸시 실패 사실을 반영하지 않습니다(로컬 커밋 해시 사용).

### 결과 표시

```markdown
✅ Commit & Push 완료: {commit_hash}
```

---

## 단계 9: 수정 완료 댓글 작성 (appropriate + 수정된 항목, 필수)

### 댓글 작성 조건

**단계 6에서 실제로 코드를 수정한 appropriate 코멘트에는 반드시 댓글을 작성합니다.**

- 사용자 확인 불필요 — 수정이 완료된 항목은 자동으로 댓글 작성
- 사용자가 수정을 스킵한 항목([수정 안함] 선택 등)에는 작성하지 않음
- merged/closed PR 등으로 댓글 작성이 불가능한 경우 스킵하고 최종 보고에 표시

### 댓글 내용

지적의 **타당성**과 **수정한 내용**을 정리하여 작성합니다. **반드시 한국어로 작성합니다.**

```markdown
@coderabbitai 지적이 타당하여 수정했습니다. 감사합니다!

**타당성**: {지적이 왜 타당한지 요약 — 분석 단계의 analysis 활용}

**수정 내용**: {무엇을 어떻게 수정했는지 정리}

수정 커밋: {commit_hash}
```

### GitHub API 호출

```bash
# 해당 리뷰 코멘트에 답장
gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies \
  --method POST \
  -f body="@coderabbitai 지적이 타당하여 수정했습니다. ..."
```

---

## 단계 10: 최종 보고 (메인 에이전트)

```markdown
## Review Analysis Complete

### Summary

- **PR:** #{pr_number}
- **Total Comments:** {total}
- **Appropriate:** {appropriate_count}
- **Responses Posted:** {response_count}
- **Code Fixed:** {fixed_count}

### Actions Taken

- ✅ {n} comments analyzed and summarized
- 💬 {n} rebuttal comments posted to GitHub
- 🔧 {n} code fixes applied
- 📝 {n} fix-summary comments posted to GitHub
- 🔍 Type verification: {pass/fail/skipped}
- 📦 Commit & Push: {commit_hash} (if committed)

### Next Steps

- 응답한 항목은 CodeRabbit 응답 대기
- 수정하지 않은 Minor 항목 검토 (선택)
```

---

## 에러 처리

### API 오류

- 404: PR 번호 확인 요청
- 403: `gh auth login` 상태 확인

### 파일 읽기 실패

- 삭제된 파일: 분석 스킵 후 사용자에게 알림

---

## 예시 실행

```
사용자: /resolve-coderabbit-review 5665

Claude:
## CodeRabbit Review Analysis for PR #5665

**Total Comments:** 5 | ✅ Appropriate: 4 | ⚠️ Needs Response: 1

---

### ✅ 적절한 지적 (수정 후 댓글 작성 예정)

**1. WORKFLOW.md:207 - export 방식 불일치** 🔴 Critical
- 요약: default export와 named import가 혼용됨
- 분석: 실제로 템플릿 간 불일치로 컴파일 에러 발생 가능
- 권장: named export로 통일 필요

**2. figma-preprocess.sh:39 - 정규식 한계** 🟠 Major
- 요약: 중첩 var() 처리 시 정규식 한계
- 분석: `var(--a, var(--b, #fff))` 케이스에서 실제로 문제 발생 가능
- 권장: 주석 완화하여 한계 명시

**3. fe-fundamental.md:5 - 빈 필드** 🟡 Minor
- 요약: description과 globs 필드가 비어있음
- 분석: 다른 .md 파일도 동일한 패턴 사용, 로더가 거부하지 않음
- 권장: 필드 값 추가 또는 주석으로 의도 명시

**4. fe-fundamental.md:9 - 모호한 문장** 🟡 Minor
- 요약: "conflict 시 they should be ignored" 의미 불명확
- 분석: 우선순위 해석이 갈릴 수 있음
- 권장: "다른 룰 우선" 등으로 명확화

---

### ⚠️ 응답 필요 (GitHub 댓글 작성 예정)

**5. preview.css:36 - CSS 변수 미정의** 🔴 Critical
- CodeRabbit 지적: --bg-color, --bg-font-color가 정의되지 않음
- 분석: 실제로 ThemeDecorator에서 런타임에 동적 주입됨
- 반박 이유: CodeRabbit이 정적 분석에서 동적 주입을 놓침
- 작성할 GitHub 댓글: "CSS variables are dynamically injected by ThemeDecorator at runtime in Storybook"

---

반박 댓글을 작성하시겠습니까?

(사용자가 [작성] 선택 후)

---

다음 CodeRabbit 지적에 대해 코드를 수정하시겠습니까?

🔴🟠 수정 권장:
1. WORKFLOW.md:207 - export 방식 불일치 🔴
2. figma-preprocess.sh:39 - 정규식 한계 🟠

🟡 참고 (Minor):
3. fe-fundamental.md:5 - 빈 필드
4. fe-fundamental.md:9 - 모호한 문장

옵션: [모두 수정] [선택 수정] [수정 안함]

(사용자가 [모두 수정] 선택 후)

코드 수정 완료 → 타입 검증 통과 → 자동 커밋 & 푸시

✅ Commit & Push 완료: abc1234

수정 완료 댓글 작성 중...

📝 WORKFLOW.md:207 - "@coderabbitai 지적이 타당하여 수정했습니다. named export로 통일했습니다. (수정 커밋: abc1234)"
📝 figma-preprocess.sh:39 - "@coderabbitai 지적이 타당하여 수정했습니다. 정규식 한계를 주석으로 명시했습니다. (수정 커밋: abc1234)"

수정 완료 댓글 2건 작성됨.
```
