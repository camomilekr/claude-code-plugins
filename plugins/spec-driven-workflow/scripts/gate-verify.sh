#!/bin/bash
# G1 게이트 — 결정론적 검증 (docs/design.md 6-1절, rules/core.md "게이트" 절)
#
# 프로젝트가 .claude/spec-workflow.json 에 선언한 verify·test·e2e 명령을
# 한 번의 호출로 묶어 실행하고, 실패하면 실패 출력만 모아 반환한다.
# 게이트는 기계적 사실(exit code)만 판정한다 — 원인 해석은 이 출력을 받는 에이전트의 일이다.
#
# 사용법:
#   gate-verify.sh [--config <경로>] [--manifest <경로>] [--skip-e2e] [--skip-mutation] [테스트 경로...]
#
#   - commands.mutation 이 선언된 프로젝트에서는 mutation testing 도 함께 돈다
#     (스펙 표본 과적합·빈약한 단정의 기계 검출기 — docs/spec-test-gap.md 5-5).
#     타임아웃은 mutationTimeoutSeconds (기본값: timeoutSeconds)
#
#   - 현재 디렉터리(워크트리 루트)에서 실행한다. 설정 기본 경로: ./.claude/spec-workflow.json
#   - --manifest 를 주면 매니페스트의 specFiles 경로가 테스트 대상에 합쳐진다
#   - test 명령에 {paths} 자리표시자가 있으면 대상 경로로 치환된다 (경로 지정 강제)
#
# 종료 코드: 0 = 전부 통과, 1 = 하나 이상 실패, 2 = 설정·입력 오류 (침묵 통과 금지)

set -uo pipefail

CONFIG=".claude/spec-workflow.json"
MANIFEST=""
SKIP_E2E=0
SKIP_MUTATION=0
PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config)        CONFIG="$2"; shift 2 ;;
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --skip-e2e)      SKIP_E2E=1; shift ;;
    --skip-mutation) SKIP_MUTATION=1; shift ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               PATHS+=("$1"); shift ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "G1 FAIL(설정 오류) — python3 를 찾을 수 없다. 게이트 스크립트는 JSON 파싱과 타임아웃에 python3 를 쓴다." >&2
  exit 2
fi

if [ ! -f "$CONFIG" ]; then
  echo "G1 FAIL(설정 없음) — ${CONFIG} 가 없다." >&2
  echo "이 플러그인을 쓰는 프로젝트는 검증 명령을 선언해야 한다. 예시:" >&2
  echo '{ "commands": { "verify": "npm run verify", "test": "npm test -- {paths}", "e2e": "npm run test:e2e" }, "timeoutSeconds": 300 }' >&2
  echo "온보딩 절차는 rules/core.md 의 \"프로젝트 설정 계약\" 절을 따른다." >&2
  exit 2
fi

export GATE_CONFIG="$CONFIG" GATE_MANIFEST="$MANIFEST" GATE_SKIP_E2E="$SKIP_E2E" GATE_SKIP_MUTATION="$SKIP_MUTATION"
exec python3 - "${PATHS[@]+"${PATHS[@]}"}" <<'PYEOF'
import json, os, subprocess, sys

config_path = os.environ["GATE_CONFIG"]
manifest_path = os.environ["GATE_MANIFEST"]
skip_e2e = os.environ["GATE_SKIP_E2E"] == "1"
skip_mutation = os.environ["GATE_SKIP_MUTATION"] == "1"
paths = list(sys.argv[1:])

def die(msg):
    print(f"G1 FAIL(설정 오류) — {msg}", file=sys.stderr)
    sys.exit(2)

try:
    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    die(f"{config_path} 를 읽거나 파싱할 수 없다: {e}")

commands = config.get("commands") or {}
for required in ("verify", "test"):
    if not commands.get(required):
        die(f"{config_path} 의 commands.{required} 가 비어 있다. verify 와 test 는 필수다.")

timeout = config.get("timeoutSeconds", 300)
if not isinstance(timeout, (int, float)) or timeout <= 0:
    die(f"timeoutSeconds 값이 잘못됐다: {timeout!r}")

# 매니페스트의 specFiles 경로를 테스트 대상에 합친다
if manifest_path:
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        die(f"매니페스트 {manifest_path} 를 읽거나 파싱할 수 없다: {e}")
    spec_paths = [s.get("path") for s in manifest.get("specFiles") or []]
    spec_paths = [p for p in spec_paths if p]
    if not spec_paths:
        die(f"매니페스트 {manifest_path} 의 specFiles 가 비어 있다.")
    paths += [p for p in spec_paths if p not in paths]

test_cmd = commands["test"]
if "{paths}" in test_cmd:
    if not paths:
        die("test 명령에 {paths} 자리표시자가 있는데 대상 경로가 없다. "
            "테스트는 경로를 지정해 좁혀 돌린다 — 매니페스트 또는 인자로 경로를 넘겨라.")
    test_cmd = test_cmd.replace("{paths}", " ".join(paths))

mutation_timeout = config.get("mutationTimeoutSeconds", timeout)
if not isinstance(mutation_timeout, (int, float)) or mutation_timeout <= 0:
    die(f"mutationTimeoutSeconds 값이 잘못됐다: {mutation_timeout!r}")

steps = [("verify", commands["verify"], timeout), ("test", test_cmd, timeout)]
if commands.get("e2e") and not skip_e2e:
    steps.append(("e2e", commands["e2e"], timeout))
if commands.get("mutation") and not skip_mutation:
    steps.append(("mutation", commands["mutation"], mutation_timeout))

# 하나가 실패해도 나머지를 마저 돌리고 결과를 한 번에 보고한다 (요청 수 절감 레버)
results = []
for name, cmd, step_timeout in steps:
    try:
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=step_timeout)
        results.append((name, cmd, proc.returncode, proc.stdout, proc.stderr))
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = (e.stderr or b"").decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        results.append((name, cmd, "TIMEOUT", out, err + f"\n[{int(step_timeout)}초 타임아웃 초과 — 명령을 강제 종료했다]"))

failed = [r for r in results if r[2] != 0]

print("== G1 결과 ==")
for name, cmd, code, _, _ in results:
    status = "PASS" if code == 0 else f"FAIL(exit={code})"
    print(f"  [{status}] {name}: {cmd}")

# 실패한 단계만 출력 원문을 전달한다 — 성공은 조용히, 실패는 시끄럽게
for name, cmd, code, out, err in failed:
    print(f"\n---- {name} 실패 출력 (명령: {cmd}) ----")
    tail_out, tail_err = out[-8000:], err[-8000:]
    if tail_out.strip():
        print(tail_out)
    if tail_err.strip():
        print("[stderr]")
        print(tail_err)

print(f"\nG1 {'FAIL' if failed else 'PASS'}")
sys.exit(1 if failed else 0)
PYEOF
