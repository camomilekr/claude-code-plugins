# code-review-plugins

코드 리뷰 자동화를 위한 Claude Code 플러그인입니다.

## 포함된 스킬

### resolve-coderabbit-review

CodeRabbit이 남긴 PR 리뷰 코멘트를 분석하고 적절성을 판단하여 처리합니다.

```
코멘트 조회 → 이전 라운드 스레드 정리 → 각 코멘트 분석 (적절성 판단)
    ├─ ✅ appropriate    → 요약 → 코드 수정 → 타입 검증 → Commit & Push → 수정 내용 댓글
    └─ ⚠️ needs_response → GitHub 반박/보완 댓글 작성
```

**사용법**

```bash
# PR 번호 지정
/resolve-coderabbit-review 5665

# 현재 브랜치의 PR 자동 감지
/resolve-coderabbit-review
```

**주요 기능**

- resolved 코멘트를 제외한 CodeRabbit 리뷰 코멘트 수집 (코드 라인 리뷰 스레드 한정)
- 코멘트별 적절성 판단 (`appropriate` / `needs_response`)
- 적절한 지적은 사용자 확인 후 코드 수정 → 타입 검증 → 자동 커밋 & 푸시
- 부적절한 지적은 GitHub 댓글로 반박
- 수정 완료 댓글에 마커를 남기고, **다음 실행에서 CodeRabbit이 수긍한 스레드만 자동 resolve**

**안전장치**

- PR head 브랜치와 현재 브랜치가 다르면 코드 수정·커밋·푸시를 차단
- 이미 사람이 답변한 스레드에는 중복 반박 금지
- resolve 판정이 애매하면 스레드를 닫지 않음

**요구 사항**

- [gh CLI](https://cli.github.com/) 설치 및 인증 (`gh auth status`)
- `jq`, `perl` (코멘트 수집 스크립트에서 사용)
- CodeRabbit이 활성화된 GitHub 저장소
- 코드 수정·푸시를 사용하려면 대상 저장소 쓰기 권한

**타입 검증 범위**

whatap-front 저장소(`apps/whatap-front/tsconfig.app.json` 존재)에서는 수정된 모듈만 스코프 지정하여 빠르게 검사하고, 그 외 저장소에서는 `package.json`의 typecheck 스크립트 또는 `npx tsc --noEmit`을 자동 탐지합니다. 검증 실패는 커밋을 차단하지 않습니다.

## 설치

```bash
# camomilekr 마켓플레이스 추가 후
/plugin marketplace add camomilekr/claude-code-plugins
/plugin install code-review-plugins@camomilekr
```

## 라이선스

MIT
