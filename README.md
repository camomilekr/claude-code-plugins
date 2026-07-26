# camomilekr Claude Code plugins

[Claude Code](https://claude.com/claude-code) 플러그인 마켓플레이스입니다. 플러그인 본체는 각자 별도 레포에 있고, 이 레포는 목록만 관리합니다.

## 등록

```bash
claude plugin marketplace add camomilekr/claude-code-plugins
```

한 번 등록해 두면 이후 추가되는 플러그인도 같은 마켓플레이스에서 바로 설치할 수 있습니다.

## 플러그인

| 플러그인 | 설명 | 레포 |
|---|---|---|
| `ide-notify` | Claude Code가 작업을 마치거나 승인·결정을 기다릴 때 시스템 알림. macOS에서는 알림 클릭 시 세션을 띄운 터미널/IDE로 포커스 이동 | [claude-code-ide-notify](https://github.com/camomilekr/claude-code-ide-notify) |

```bash
claude plugin install ide-notify@camomilekr
```

## 마켓플레이스 갱신

플러그인을 추가하려면 `.claude-plugin/marketplace.json`의 `plugins` 배열에 항목을 넣고 푸시하면 됩니다.

```json
{
  "name": "플러그인-이름",
  "description": "한 줄 설명",
  "source": { "source": "github", "repo": "camomilekr/레포-이름" }
}
```

사용자 쪽에서는 아래로 목록을 갱신합니다.

```bash
claude plugin marketplace update camomilekr
```

## 라이선스

각 플러그인의 라이선스는 해당 레포를 따릅니다. 이 레포의 마켓플레이스 정의는 MIT입니다.
