---
name: resolve-coderabbit-review
description: |
  CodeRabbit PR 리뷰 코멘트를 분석하고 처리합니다.
  트리거 조건:
  - 키워드: "CodeRabbit", "coderabbit", "리뷰 확인", "PR 리뷰", "review comments"
  - PR 번호 또는 URL과 함께 사용
  주요 기능: 리뷰 코멘트 조회, 피드백 분석, 코드 수정, 응답 작성
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash(git *)
  - Bash(gh *)
  - Task
  - AskUserQuestion
argument-hint: /resolve-coderabbit-review [pr_number]
---

# CodeRabbit PR Review Analyzer

CodeRabbit이 남긴 PR 리뷰 코멘트를 **분석하고 적절성을 판단**하는 Skill입니다.

## 핵심 동작

```
코멘트 조회 → 각 코멘트 분석 (적절성 판단)
    ├─ ✅ 적절함 → 요약 → 코드 수정 → 타입 검증 → Commit & Push → 수정 내용 댓글 작성
    └─ ⚠️ 반박 필요 → GitHub 댓글 작성
```

**중요**:
- 지적이 타당하여 수정한 경우, 지적의 타당성과 수정 내용을 정리한 댓글을 **반드시** 작성
- 적절한 지적은 수정 대상을 사용자에게 보여주고 확인 후 진행
- 수정 완료 시 자동 커밋 & 푸시

## 사용법

```bash
# PR 리뷰 코멘트 분석
/resolve-coderabbit-review 5665

# 현재 브랜치 PR 자동 감지
/resolve-coderabbit-review
```

## 분석 기준

각 CodeRabbit 코멘트에 대해:

1. **해당 파일/라인의 코드 읽기**
2. **CodeRabbit 지적 내용 검토**
3. **판단**:
   - ✅ **적절함**: 지적이 타당하고 수정이 필요함 → 코드 수정 후 타당성 + 수정 내용 댓글 작성
   - ⚠️ **부분 적절**: 일부만 맞거나 추가 설명 필요 → GitHub 댓글 작성
   - ❌ **부적절**: 오해이거나 의도적 설계임 → GitHub 댓글로 반박

## 결과 출력 형식

```markdown
## CodeRabbit Review Analysis for PR #5665

### ✅ 적절한 지적 (수정 후 댓글 작성)

**1. WORKFLOW.md:207 - export 방식 불일치** 🔴 Critical
- 요약: default export와 named import가 혼용됨
- 분석: 실제로 템플릿 간 불일치로 컴파일 에러 발생 가능
- 권장: named export로 통일 필요
- 수정 완료 댓글: "지적이 타당합니다. named export로 통일했습니다. (커밋 abc1234)"

---

### ⚠️ 반박/보완 필요 (GitHub 댓글 작성됨)

**2. preview.css:36 - CSS 변수 미정의** 🔴 Critical
- CodeRabbit 지적: --bg-color, --bg-font-color 미정의
- 분석: 실제로 Storybook 테마 데코레이터에서 동적 주입됨
- 반박 이유: 변수는 ThemeDecorator에서 런타임에 설정됨
- GitHub 댓글: "CSS variables are dynamically injected..."
```

## 심각도 분류

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

출력에는 기본 필드 외에 `is_outdated`(이미 변경된 코드 위치에 대한 지적 여부), `reply_count`/`last_reply_author`(이미 답변한 스레드 구분 — 중복 반박 방지), `thread_id`(스레드 resolve 처리용)가 포함됩니다. 자세한 활용법은 [WORKFLOW.md](WORKFLOW.md) 참조.

### 응답 작성

반박 댓글과 수정 완료 댓글 모두 동일한 API를 사용합니다:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies \
  --method POST -f body="반박 내용 또는 타당성 인정 + 수정 내용 정리"
```

## 워크플로우 단계

자세한 단계별 지침은 [WORKFLOW.md](WORKFLOW.md)를 참조하세요.
