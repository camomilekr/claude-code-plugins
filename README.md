# camomilekr Claude Code plugins

[Claude Code](https://claude.com/claude-code) 플러그인 마켓플레이스입니다. 플러그인 본체도 이 레포의 `plugins/` 아래에서 함께 관리합니다(모노레포).

## 등록

```bash
claude plugin marketplace add camomilekr/claude-code-plugins
```

한 번 등록해 두면 이후 추가되는 플러그인도 같은 마켓플레이스에서 바로 설치할 수 있습니다.

## 플러그인

| 플러그인 | 설명 | 경로 |
|---|---|---|
| `ide-notify` | Claude Code가 작업을 마치거나, 서브에이전트가 작업을 시작·완료했거나, 승인·결정을 기다릴 때 시스템 알림. macOS에서는 알림 클릭 시 세션을 띄운 터미널/IDE로 포커스 이동 | [plugins/ide-notify](plugins/ide-notify) |
| `code-review-plugins` | 코드 리뷰 자동화 스킬 모음. CodeRabbit PR 리뷰 코멘트를 분석해 처리하는 `resolve-coderabbit-review` 스킬 제공 | [plugins/code-review](plugins/code-review) |

```bash
claude plugin install ide-notify@camomilekr
claude plugin install code-review-plugins@camomilekr
```

## 구조

```
.claude-plugin/marketplace.json   # 마켓플레이스 정의
plugins/
├── ide-notify/                   # 각 플러그인 = 하나의 디렉토리
│   └── .claude-plugin/plugin.json
└── code-review/
    └── .claude-plugin/plugin.json
```

## 플러그인 추가

1. `plugins/<이름>/` 디렉토리를 만들고 `.claude-plugin/plugin.json`을 작성합니다.
2. `.claude-plugin/marketplace.json`의 `plugins` 배열에 항목을 추가합니다.

```json
{
  "name": "플러그인-이름",
  "description": "한 줄 설명",
  "source": "./plugins/플러그인-이름"
}
```

사용자 쪽에서는 아래로 목록을 갱신합니다.

```bash
claude plugin marketplace update camomilekr
```

## 라이선스

MIT
