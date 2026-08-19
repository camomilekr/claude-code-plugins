#!/bin/bash
# SessionStart 훅 — 플러그인 rules/*.md 를 세션 컨텍스트로 주입한다.
# 플러그인은 rules/ 디렉토리 자동 로드를 지원하지 않으므로
# (공식 컴포넌트: skills/commands/agents/hooks 등) 이 훅이 그 역할을 대신한다.
# ref/ 아래 참조 문서는 의도적으로 주입하지 않는다 — 필요할 때만 읽는 문서다.

set -euo pipefail

RULES_DIR="${CLAUDE_PLUGIN_ROOT}/rules"

[ -d "$RULES_DIR" ] || exit 0

echo "<spec-driven-workflow-plugin-rules>"
echo "spec-driven-workflow 플러그인의 워크플로우 규칙이다. 플러그인 루트: ${CLAUDE_PLUGIN_ROOT}"
echo "규칙 안의 \`agents/\`·\`scripts/\`·\`ref/\` 상대 경로는 이 플러그인 루트 기준이다. 게이트 스크립트는 \${CLAUDE_PLUGIN_ROOT}/scripts/ 아래의 실행 파일이다."

for f in "$RULES_DIR"/*.md; do
  echo ""
  echo "---"
  echo ""
  cat "$f"
done

echo "</spec-driven-workflow-plugin-rules>"
