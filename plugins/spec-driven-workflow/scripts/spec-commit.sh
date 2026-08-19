#!/bin/bash
# 스펙 커밋 — G2 무변경 검사의 기준점을 고정한다 (rules/core.md "스펙" 절, docs/decisions.md (5))
#
# 매니페스트의 specFiles·scaffoldFiles 만 스테이징해 커밋하고(경로 지정 규율),
# 커밋 해시를 매니페스트의 specCommit 에 기록한다. 기준점 고정을 LLM 손이 아니라
# 스크립트에 맡기기 위한 것이다. 매니페스트 자체(docs/plan/)는 커밋하지 않는다.
#
# 커밋 전에 요구사항 추적 검사를 한다 (docs/spec-test-gap.md 5-3):
#   계획서(manifest.plan)의 모든 [테스트] 검증 항목(| Vn | … | [테스트] |)이
#   specFiles 의 covers 에 최소 1개 매핑되어 있어야 한다. 항목이 통째로 빠지는
#   과소포괄을 developer 가 구현을 시작하기 전, 스펙이 동결되는 지점에서 잡는다.
#
# 사용법:
#   spec-commit.sh --manifest <경로> [-m <커밋 메시지>]
#
#   - 현재 디렉터리(워크트리 루트)에서 실행한다.
#   - 기본 메시지: "{task} 완료 기준을 스펙 테스트로 고정"
#
# 종료 코드: 0 = 커밋 완료·해시 기록, 2 = 입력·상태 오류 (이미 커밋됨 포함)

set -uo pipefail

MANIFEST=""
MESSAGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    -m)         MESSAGE="$2"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "스펙 커밋 실패(입력 오류) — 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
  echo "스펙 커밋 실패(입력 오류) — --manifest 로 존재하는 매니페스트를 넘겨라: '${MANIFEST}'" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "스펙 커밋 실패(설정 오류) — python3 를 찾을 수 없다." >&2
  exit 2
fi

export SPEC_MANIFEST="$MANIFEST" SPEC_MESSAGE="$MESSAGE"
exec python3 - <<'PYEOF'
import json, os, re, subprocess, sys

manifest_path = os.environ["SPEC_MANIFEST"]
message = os.environ["SPEC_MESSAGE"]

def die(msg):
    print(f"스펙 커밋 실패 — {msg}", file=sys.stderr)
    sys.exit(2)

def run(args):
    return subprocess.run(args, capture_output=True, text=True)

try:
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    die(f"매니페스트 {manifest_path} 를 읽거나 파싱할 수 없다: {e}")

if manifest.get("specCommit"):
    die(f"specCommit 이 이미 기록돼 있다: {manifest['specCommit']}. "
        "스펙을 다시 고정하려면 spec-writer 재호출 후 매니페스트의 specCommit 을 null 로 되돌리고 다시 실행해라 — "
        "기존 기준점을 덮어쓰는 것은 의도된 재고정일 때만 허용된다.")

spec_entries = manifest.get("specFiles") or []
spec_files = [s.get("path") for s in spec_entries]
spec_files = [p for p in spec_files if p]
if not spec_files:
    die("specFiles 가 비어 있다. 고정할 스펙이 없다.")
scaffold_files = [p for p in manifest.get("scaffoldFiles") or [] if p]

# ── 요구사항 추적 검사: 계획서의 [테스트] 항목 전부가 covers 에 매핑됐는가
plan_path = manifest.get("plan")
if not plan_path:
    die("매니페스트에 plan(계획서 경로)이 없다. 검증 항목 매핑 검사를 할 수 없다 — "
        "spec-writer 산출물 스키마(agents/spec-writer.md)를 확인해라.")
try:
    with open(plan_path, encoding="utf-8") as f:
        plan_text = f.read()
except OSError as e:
    die(f"계획서 {plan_path} 를 읽을 수 없다: {e}")

all_ids, test_ids = set(), set()
for line in plan_text.splitlines():
    m = re.match(r"^\|\s*(V\d+)\s*\|", line)
    if not m:
        continue
    all_ids.add(m.group(1))
    if "[테스트]" in line:
        test_ids.add(m.group(1))

if not all_ids:
    die(f"계획서 {plan_path} 에서 검증 항목(| V1 | … |)을 찾지 못했다. "
        "계획서의 '검증 항목' 표 형식이 규정(agents/architect.md)과 다르다 — 침묵 통과 대신 여기서 멈춘다.")

def vnum(v): return int(v[1:])
covered = set()
for s in spec_entries:
    covered |= {c for c in (s.get("covers") or []) if c}

unknown = sorted(covered - all_ids, key=vnum)
if unknown:
    die("covers 가 계획서에 없는 검증 항목 ID 를 참조한다: " + ", ".join(unknown) + ". "
        "오기이거나 계획서와 매니페스트가 어긋난 것이다.")

missing = sorted(test_ids - covered, key=vnum)
if missing:
    die("계획서의 [테스트] 검증 항목 중 어떤 스펙에도 매핑되지 않은 것이 있다: " + ", ".join(missing) + ". "
        "스펙을 추가하거나, 스펙으로 옮길 수 없는 항목이면 계획 결함으로 보고해라 — 항목을 조용히 떨어뜨리는 경로는 없다.")

print(f"== 요구사항 추적 검사 통과 — [테스트] 항목 {len(test_ids)}개 전부 매핑됨 "
      f"(계획서 항목 {len(all_ids)}개, 매핑 {len(covered)}개) ==")

targets = spec_files + [p for p in scaffold_files if p not in spec_files]
missing = [p for p in targets if not os.path.exists(p)]
if missing:
    die("작업 트리에 없는 파일이 매니페스트에 등재돼 있다: " + ", ".join(missing))

# 경로 지정 규율 — 등재된 파일만 스테이징한다. git add -A 금지의 스크립트 판이다.
added = run(["git", "add", "--"] + targets)
if added.returncode != 0:
    die(f"git add 실패: {added.stderr.strip()}")

# 스테이징된 것이 실제로 있는지 확인한다 (전부 무변경이면 빈 커밋이 된다)
staged = run(["git", "diff", "--cached", "--name-only", "--"] + targets)
if not staged.stdout.strip():
    die("등재된 파일에 커밋할 변경이 없다. 스펙 파일이 이미 커밋됐다면 그 커밋 해시를 확인해라.")

if not message:
    task = manifest.get("task") or "작업"
    message = f"{task} 완료 기준을 스펙 테스트로 고정"

committed = run(["git", "commit", "-m", message, "--"] + targets)
if committed.returncode != 0:
    print(committed.stdout, end="")
    print(committed.stderr, file=sys.stderr, end="")
    die("git commit 이 실패했다. pre-commit 훅(verify)이 막았다면 스펙·스캐폴드가 린트·타입 검사를 "
        "통과하는지부터 확인해라 — 테스트 red 는 정상이지만 컴파일 실패는 스펙 고장이다.")

head = run(["git", "rev-parse", "HEAD"])
if head.returncode != 0:
    die(f"git rev-parse HEAD 실패: {head.stderr.strip()}")
commit_hash = head.stdout.strip()

manifest["specCommit"] = commit_hash
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")

print("== 스펙 커밋 완료 ==")
print(f"  커밋: {commit_hash}")
print(f"  메시지: {message}")
print(f"  specFiles {len(spec_files)}개 / scaffoldFiles {len(scaffold_files)}개")
print(f"  매니페스트에 specCommit 기록됨: {manifest_path}")
PYEOF
