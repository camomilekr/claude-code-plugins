# code-review-plugins

코드 리뷰 자동화를 위한 Claude Code 플러그인입니다.

## 포함된 스킬

### resolve-coderabbit-review

CodeRabbit이 남긴 PR 리뷰 코멘트를 분석하고 적절성을 판단하여 처리합니다.

```
코멘트 조회 → 각 코멘트 분석 (적절성 판단)
    ├─ ✅ 적절함 → 요약 → 코드 수정 → 타입 검증 → Commit
    └─ ⚠️ 반박 필요 → GitHub 댓글 작성
```

**사용법**

```bash
# PR 번호 지정
/resolve-coderabbit-review 5665

# 현재 브랜치의 PR 자동 감지
/resolve-coderabbit-review
```

**주요 기능**

- resolved 코멘트를 제외한 CodeRabbit 리뷰 코멘트 수집
- 코멘트별 적절성 판단 (적절함 / 부분 적절 / 부적절)
- 적절한 지적은 사용자 확인 후 코드 수정 및 커밋
- 부적절한 지적은 GitHub 댓글로 반박

**요구 사항**

- [gh CLI](https://cli.github.com/) 설치 및 인증
- CodeRabbit이 활성화된 GitHub 저장소

## 설치

```bash
# camomilekr 마켓플레이스 추가 후
/plugin marketplace add camomilekr/claude-code-plugins
/plugin install code-review-plugins@camomilekr
```

## 라이선스

MIT
