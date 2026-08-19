#!/bin/bash
# G2 게이트 — 스펙 무결성 (docs/design.md 6-2절, rules/core.md "게이트" 절)
#
# 검사 두 가지, 전부 결정론적이다:
#   1. 무변경 검사 — 스펙 커밋 이후 매니페스트 등재 스펙 파일(specFiles)이 조금이라도
#      바뀌었으면(커밋 여부 무관, 작업 트리 포함) 실패. developer 가 스펙을 약화시키는 경로를 차단한다.
#      scaffoldFiles 는 구현으로 채우라고 만든 파일이므로 검사 대상이 아니다.
#   2. green 검사 — 매니페스트의 모든 스펙 파일을 test 명령으로 실행해 전부 통과해야 성공.
#      (red 실측 기록이 매니페스트에 있으므로 "red였던 것이 green이 됐다"가 이 시점에 성립한다)
#
# 사용법:
#   spec-guard.sh --manifest <경로> [--config <경로>]
#
#   - 현재 디렉터리(워크트리 루트)에서 실행한다. 설정 기본 경로: ./.claude/spec-workflow.json
#
# 종료 코드: 0 = 통과, 1 = 검사 실패, 2 = 설정·입력 오류 (침묵 통과 금지)

set -uo pipefail

CONFIG=".claude/spec-workflow.json"
MANIFEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "G2 FAIL(입력 오류) — 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$MANIFEST" ]; then
  echo "G2 FAIL(입력 오류) — --manifest 가 필요하다." >&2
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  echo "G2 FAIL(입력 오류) — 매니페스트가 없다: $MANIFEST" >&2
  exit 2
fi
if [ ! -f "$CONFIG" ]; then
  echo "G2 FAIL(설정 없음) — ${CONFIG} 가 없다. green 검사에 test 명령이 필요하다." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "G2 FAIL(설정 오류) — python3 를 찾을 수 없다." >&2
  exit 2
fi

export GATE_CONFIG="$CONFIG" GATE_MANIFEST="$MANIFEST"
exec python3 - <<'PYEOF'
import json, os, subprocess, sys

config_path = os.environ["GATE_CONFIG"]
manifest_path = os.environ["GATE_MANIFEST"]

def die(msg):
    print(f"G2 FAIL(입력 오류) — {msg}", file=sys.stderr)
    sys.exit(2)

try:
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    die(f"매니페스트 {manifest_path} 를 읽거나 파싱할 수 없다: {e}")

try:
    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    die(f"{config_path} 를 읽거나 파싱할 수 없다: {e}")

spec_commit = manifest.get("specCommit")
if not spec_commit:
    die("매니페스트의 specCommit 이 비어 있다. 스펙 커밋(scripts/spec-commit.sh)이 먼저다 — "
        "커밋 없이 G2 를 돌리면 무변경 검사의 기준점이 없다.")

spec_files = [s.get("path") for s in manifest.get("specFiles") or []]
spec_files = [p for p in spec_files if p]
if not spec_files:
    die("매니페스트의 specFiles 가 비어 있다.")

test_cmd_tpl = (config.get("commands") or {}).get("test")
if not test_cmd_tpl:
    die(f"{config_path} 의 commands.test 가 비어 있다.")
timeout = config.get("timeoutSeconds", 300)

# 스펙 커밋이 실제로 존재하는지 확인한다
probe = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{spec_commit}^{{commit}}"],
                       capture_output=True, text=True)
if probe.returncode != 0:
    die(f"specCommit {spec_commit} 이 이 저장소에 없다. 다른 워크트리의 커밋이거나 잘못 기록된 해시다.")

failures = []

# ── 검사 1: 무변경 — 스펙 커밋 대비 작업 트리(미커밋 변경 포함)를 본다
diff = subprocess.run(["git", "diff", "--name-only", spec_commit, "--"] + spec_files,
                      capture_output=True, text=True)
if diff.returncode != 0:
    die(f"git diff 실패: {diff.stderr.strip()}")
changed = [line for line in diff.stdout.splitlines() if line.strip()]

missing = [p for p in spec_files if not os.path.exists(p)]

print("== G2 검사 1: 스펙 무변경 ==")
if changed or missing:
    for p in changed:
        print(f"  [FAIL] 스펙 커밋 이후 변경됨: {p}")
    for p in missing:
        if p not in changed:
            print(f"  [FAIL] 작업 트리에 없음: {p}")
    failures.append("스펙 파일이 스펙 커밋 이후 변경·삭제됐다. 스펙은 완료 기준이다 — "
                    "스펙이 틀렸다면 수정이 아니라 spec-writer 재호출이 경로다.")
else:
    print(f"  [PASS] specFiles {len(spec_files)}개 전부 스펙 커밋 {spec_commit[:12]} 과 동일")

# ── 검사 2: green — 모든 스펙 파일이 통과해야 한다
if "{paths}" in test_cmd_tpl:
    test_cmd = test_cmd_tpl.replace("{paths}", " ".join(spec_files))
else:
    test_cmd = test_cmd_tpl

print("== G2 검사 2: 스펙 green ==")
try:
    proc = subprocess.run(test_cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    if proc.returncode == 0:
        print(f"  [PASS] {test_cmd}")
    else:
        print(f"  [FAIL(exit={proc.returncode})] {test_cmd}")
        print(f"\n---- 테스트 실패 출력 ----")
        if proc.stdout.strip():
            print(proc.stdout[-8000:])
        if proc.stderr.strip():
            print("[stderr]")
            print(proc.stderr[-8000:])
        failures.append("스펙 테스트가 전부 green 이 아니다.")
except subprocess.TimeoutExpired:
    print(f"  [FAIL(TIMEOUT)] {test_cmd} — {int(timeout)}초 초과")
    failures.append(f"스펙 테스트 실행이 {int(timeout)}초를 넘겨 강제 종료됐다.")

if failures:
    print("\nG2 FAIL")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("\nG2 PASS")
PYEOF
