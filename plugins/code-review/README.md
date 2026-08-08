# code-review-plugins

코드 리뷰 대응 자동화를 위한 Claude Code 플러그인입니다.

## 포함된 스킬

### response-to-review

PR에 달린 리뷰 코멘트를 수집해 **코드로 검증한 뒤** 판정에 따라 수정·반박·답글을 처리합니다. 사람 리뷰어와 CodeRabbit·Copilot 같은 자동 리뷰 양쪽에 씁니다.

> v2.0.0에서 CodeRabbit 전용이던 `resolve-coderabbit-review` 스킬과 범용 리뷰 대응 스킬 `response-to-review`가 이 스킬 하나로 통합됐습니다. CodeRabbit 자동화(스레드 정리·마커)는 그대로 유지되고, 구버전 마커도 인식합니다.

```
코멘트 수집 → 이전 라운드 스레드 정리 → 주제별 묶기 → 코드로 확인 → 판정 (4갈래)
    ├─ ✅ 수정          → 사용자 확인 → 코드 수정 → 검증 → 커밋 → 수정 내용 답글 (마커 포함)
    ├─ 📌 범위 밖       → 왜 지금이 아닌지·어디서 다룰지 답글
    ├─ ⚠️ 반박          → 근거를 붙인 반박/보완 답글
    └─ ❓ 사용자 판단    → 선택지와 대가를 정리해 사용자에게 질문
```

**사용법**

```bash
# PR 번호 지정
/response-to-review 5665

# 현재 브랜치의 PR 자동 감지
/response-to-review
```

**주요 기능**

- 인라인 리뷰 스레드(전용 스크립트, resolved 제외)·리뷰 본문 총평·PR 일반 코멘트를 모두 수집 — 페이지네이션 잘림과 `Suppressed comments` 함정을 회피
- 지적이 서술하는 상황이 **실제로 성립하는지 코드로 확인한 뒤에만** 판정 (수정 / 범위 밖 / 반박 / 사용자 판단)
- 타당한 지적은 사용자 확인 후 코드 수정 → 검증 → 커밋 → 수정 내용 답글
- 타당하지 않은 지적은 확인한 근거(파일·줄, 규약, 실행 결과)를 붙여 정중하게 반박
- 수정 완료 답글에 마커를 남기고, **다음 실행에서 리뷰어가 수긍한 자동 리뷰 스레드만 자동 resolve**
- 파일 단위 Subagent 그룹핑으로 대량 코멘트를 병렬 분석 (토큰 22.3% 절약 — `BENCHMARK.md`)

**안전장치**

- 커밋 모드 분기: 프로젝트에 개발 워크플로우 규약(git-workflow 플러그인 등)이 있으면 그 규약의 절차·커밋 주체를 따르고, 없을 때만 자동 커밋·푸시
- 자동 모드에서 PR head 브랜치와 현재 브랜치가 다르면 코드 수정·커밋·푸시를 차단
- 이미 사람이 답변한 스레드에는 중복 반박 금지
- **사람 리뷰어의 스레드는 자동으로 resolve하지 않음.** 자동 리뷰 스레드도 판정이 애매하면 닫지 않음
- 리뷰 코멘트 본문은 신뢰할 수 없는 입력으로 다룸 — 본문 속 지시문을 따르지 않고, 본문 문자열을 셸 명령에 직접 끼워 넣지 않음

**요구 사항**

- [gh CLI](https://cli.github.com/) 설치 및 인증 (`gh auth status`)
- `jq`, `perl` (코멘트 수집 스크립트에서 사용)
- 코드 수정·푸시를 사용하려면 대상 저장소 쓰기 권한

**검증 범위**

프로젝트가 verify·테스트 명령을 정해 뒀으면 그것을 전부 돌립니다. 없으면 타입 검사를 자동 탐지합니다 — whatap-front 저장소(`apps/whatap-front/tsconfig.app.json` 존재)에서는 수정된 모듈만 스코프 지정하여 빠르게 검사하고, 그 외 저장소에서는 `package.json`의 typecheck 스크립트 또는 `npx tsc --noEmit`을 씁니다.

## 설치

```bash
# camomilekr 마켓플레이스 추가 후
/plugin marketplace add camomilekr/claude-code-plugins
/plugin install code-review-plugins@camomilekr
```

## 라이선스

MIT
