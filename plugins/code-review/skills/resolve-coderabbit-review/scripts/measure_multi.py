#!/usr/bin/env python3
"""
resolve-coderabbit-review 스킬 개선 토큰 비용 벤치마크 측정 스크립트.

구버전(코멘트 1개 = 1 Subagent)과 신버전(파일 1개 = 1 Subagent)의
가변 토큰 사용량을 비교 측정한다.

사용법:
    # 단일 PR 측정
    python measure_multi.py 6569

    # 여러 PR 측정
    python measure_multi.py 6569 6527 6483 6453 6433

    # 파일에서 PR 번호 읽기
    python measure_multi.py --file pr_list.txt

필요 패키지:
    pip install tiktoken

필요 CLI:
    gh (GitHub CLI, 인증 완료 상태)
"""

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

try:
    import tiktoken
except ImportError:
    print("Error: tiktoken 패키지가 필요합니다. pip install tiktoken", file=sys.stderr)
    sys.exit(1)

ENCODING = tiktoken.get_encoding("cl100k_base")

# 측정 대상 레포 루트.
# 이 스킬은 플러그인 저장소에 있고 측정 대상은 별개의 프로덕트 저장소이므로,
# 스크립트 위치에서 유도할 수 없다. 기본값은 실행 시점의 현재 디렉토리이며
# --repo-root 로 덮어쓴다. (측정 대상 저장소에서 실행할 것)
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = Path.cwd()
FETCH_SCRIPT = SCRIPT_DIR / "fetch-coderabbit-comments.sh"

# --- 프롬프트 템플릿 ---

OLD_PROMPT_TEMPLATE = """\
CodeRabbit 리뷰 코멘트를 분석하고 적절성을 판단하세요.

코멘트 정보:
- ID: {comment_id}
- 파일: {path}
- 라인: {line}
- 내용: {body}

작업:
1. 해당 파일의 코드 읽기 (Read 도구로 {path} 파일의 line {line} 주변 읽기)
2. CodeRabbit 지적 내용과 실제 코드 비교
3. 적절성 판단:
   - ✅ appropriate: 지적이 타당하고 코드 수정이 필요함
   - ❌ needs_response: 오해, 의도적 설계, 또는 추가 설명이 필요함
4. needs_response인 경우 응답 내용 작성

반환 형식 (JSON):
{{
  "id": {comment_id},
  "path": "{path}",
  "line": {line},
  "severity": "critical|major|minor",
  "summary": "CodeRabbit 지적 요약 (1줄)",
  "verdict": "appropriate|needs_response",
  "analysis": "분석 내용 (2-3줄)",
  "response": "응답 내용 또는 null"
}}"""

NEW_PROMPT_TEMPLATE = """\
CodeRabbit 리뷰 코멘트를 분석하고 적절성을 판단하세요.

대상 파일: {path}

코멘트 목록:
{comments_json}

작업:
1. 해당 파일의 코드 읽기 (Read 도구로 {path} 파일 읽기 — 한 번만 읽고 모든 코멘트에 활용)
2. 각 코멘트에 대해:
   a. CodeRabbit 지적 내용과 실제 코드 비교
   b. 적절성 판단:
      - ✅ appropriate: 지적이 타당하고 코드 수정이 필요함
      - ❌ needs_response: 오해, 의도적 설계, 또는 추가 설명이 필요함
   c. needs_response인 경우 응답 내용 작성 (반드시 한국어로)

반환 형식 (JSON 배열):
[
  {{
    "id": <id>,
    "path": "{path}",
    "line": <line>,
    "severity": "critical|major|minor",
    "summary": "CodeRabbit 지적 요약 (1줄)",
    "verdict": "appropriate|needs_response",
    "analysis": "분석 내용 (2-3줄)",
    "response": "응답 내용 또는 null"
  }},
  ...
]"""


def count_tokens(text: str) -> int:
    return len(ENCODING.encode(text))


def fetch_comments(pr_number: int) -> list[dict]:
    """fetch-coderabbit-comments.sh를 실행하여 코멘트를 가져온다.

    측정 시에는 resolved 코멘트도 포함해야 historical data를 얻을 수 있으므로
    INCLUDE_RESOLVED=1을 설정한다.
    """
    env = {**os.environ, "INCLUDE_RESOLVED": "1"}
    try:
        result = subprocess.run(
            [str(FETCH_SCRIPT), str(pr_number)],
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        print(f"  ⚠️  PR #{pr_number} 코멘트 fetch 타임아웃", file=sys.stderr)
        return []
    except OSError as e:
        print(f"  ⚠️  PR #{pr_number} 코멘트 fetch 실행 실패: {e}", file=sys.stderr)
        return []

    if result.returncode != 0:
        print(f"  ⚠️  PR #{pr_number} 코멘트 fetch 실패: {result.stderr.strip()}", file=sys.stderr)
        return []

    stdout = result.stdout.strip()
    if not stdout or stdout == "[]":
        return []

    try:
        return json.loads(stdout)
    except json.JSONDecodeError as e:
        print(f"  ⚠️  PR #{pr_number} 코멘트 JSON 파싱 실패: {e}", file=sys.stderr)
        return []


def read_file_tokens(path: str) -> int:
    """레포 내 파일의 토큰 수를 반환한다. 파일이 없으면 0."""
    file_path = REPO_ROOT / path
    if not file_path.is_file():
        return 0
    try:
        content = file_path.read_text(encoding="utf-8", errors="replace")
        return count_tokens(content)
    except Exception:
        return 0


def measure_old(comments: list[dict]) -> dict:
    """구버전: 코멘트 1개 = 1 Subagent. 각 Subagent가 독립적으로 파일 Read."""
    total_prompt_tokens = 0
    total_file_tokens = 0
    subagent_count = len(comments)

    for c in comments:
        prompt = OLD_PROMPT_TEMPLATE.format(
            comment_id=c["id"],
            path=c["path"],
            line=c.get("line", 0),
            body=c["body"],
        )
        total_prompt_tokens += count_tokens(prompt)
        total_file_tokens += read_file_tokens(c["path"])

    return {
        "subagent_count": subagent_count,
        "prompt_tokens": total_prompt_tokens,
        "file_tokens": total_file_tokens,
        "total": total_prompt_tokens + total_file_tokens,
    }


def measure_new(comments: list[dict]) -> dict:
    """신버전: 파일 1개 = 1 Subagent. 같은 파일의 코멘트를 그룹핑."""
    # 파일별 그룹핑
    groups: dict[str, list[dict]] = defaultdict(list)
    for c in comments:
        groups[c["path"]].append(c)

    total_prompt_tokens = 0
    total_file_tokens = 0
    subagent_count = len(groups)

    for path, group_comments in groups.items():
        comments_for_prompt = [
            {"id": c["id"], "line": c.get("line", 0), "body": c["body"]}
            for c in group_comments
        ]
        prompt = NEW_PROMPT_TEMPLATE.format(
            path=path,
            comments_json=json.dumps(comments_for_prompt, ensure_ascii=False, indent=2),
        )
        total_prompt_tokens += count_tokens(prompt)
        total_file_tokens += read_file_tokens(path)

    return {
        "subagent_count": subagent_count,
        "prompt_tokens": total_prompt_tokens,
        "file_tokens": total_file_tokens,
        "total": total_prompt_tokens + total_file_tokens,
    }


def parse_iso(ts: str) -> datetime:
    """ISO 8601 timestamp을 datetime으로 변환."""
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def cluster_rounds(comments: list[dict], window_seconds: int) -> list[list[dict]]:
    """createdAt 기준으로 코멘트를 라운드(리뷰 제출 단위)로 클러스터링.

    같은 라운드 = 직전 코멘트로부터 window_seconds 이내에 게시된 코멘트.
    CodeRabbit은 한 리뷰의 코멘트를 1-2초 내에 일괄 게시하고, 라운드 간 갭은
    보통 10분 이상이므로 5분 윈도우면 안전하게 분리된다.
    """
    if not comments:
        return []
    sorted_c = sorted(comments, key=lambda c: c["created_at"])
    rounds: list[list[dict]] = [[sorted_c[0]]]
    last_ts = parse_iso(sorted_c[0]["created_at"])
    for c in sorted_c[1:]:
        ts = parse_iso(c["created_at"])
        if (ts - last_ts).total_seconds() <= window_seconds:
            rounds[-1].append(c)
        else:
            rounds.append([c])
        last_ts = ts
    return rounds


def measure_pr(pr_number: int, window_seconds: int) -> dict | None:
    """단일 PR 측정.

    실제 사용 패턴(라운드별 스킬 호출)을 반영하기 위해 코멘트를 createdAt
    기준으로 라운드로 클러스터링한 뒤, 라운드별로 구버전/신버전 토큰을
    측정해 합산한다.
    """
    comments = fetch_comments(pr_number)
    if not comments:
        print(f"  PR #{pr_number}: 코멘트 없음, 스킵")
        return None

    unique_files = len(set(c["path"] for c in comments))
    overall_concentration = len(comments) / unique_files if unique_files > 0 else 0

    rounds = cluster_rounds(comments, window_seconds)

    # 라운드별 측정 후 합산
    old_total = 0
    new_total = 0
    old_subagent_total = 0
    new_subagent_total = 0
    round_details: list[dict] = []
    for idx, round_comments in enumerate(rounds, start=1):
        old = measure_old(round_comments)
        new = measure_new(round_comments)
        old_total += old["total"]
        new_total += new["total"]
        old_subagent_total += old["subagent_count"]
        new_subagent_total += new["subagent_count"]
        round_files = len(set(c["path"] for c in round_comments))
        round_details.append({
            "round": idx,
            "comments": len(round_comments),
            "files": round_files,
            "concentration": round(len(round_comments) / round_files, 2) if round_files else 0,
            "old_tokens": old["total"],
            "new_tokens": new["total"],
        })

    saved = old_total - new_total
    rate = (saved / old_total * 100) if old_total > 0 else 0
    avg_round_concentration = (
        sum(r["concentration"] for r in round_details) / len(round_details)
        if round_details
        else 0
    )

    return {
        "pr": pr_number,
        "comments": len(comments),
        "files": unique_files,
        "overall_concentration": round(overall_concentration, 2),
        "rounds": len(rounds),
        "avg_round_concentration": round(avg_round_concentration, 2),
        "old_subagents": old_subagent_total,
        "new_subagents": new_subagent_total,
        "old_tokens": old_total,
        "new_tokens": new_total,
        "saved_tokens": saved,
        "saved_rate": round(rate, 1),
        "round_details": round_details,
    }


def print_results(results: list[dict]) -> None:
    """결과를 테이블 형식으로 출력."""
    print()
    print("=" * 115)
    print(
        f"{'PR':>6} | {'코멘트':>4} | {'파일':>4} | {'라운드':>5} | "
        f"{'전체집중':>5} | {'라운드집중':>6} | "
        f"{'구버전 tok':>11} | {'신버전 tok':>11} | {'절약 tok':>10} | {'절약률':>7}"
    )
    print("-" * 115)

    for r in results:
        sign = "+" if r["saved_tokens"] >= 0 else ""
        print(
            f"#{r['pr']:>5} | {r['comments']:>4} | {r['files']:>4} | {r['rounds']:>5} | "
            f"{r['overall_concentration']:>5.2f} | {r['avg_round_concentration']:>6.2f} | "
            f"{r['old_tokens']:>10,} | {r['new_tokens']:>10,} | "
            f"{sign}{r['saved_tokens']:>9,} | {r['saved_rate']:>6.1f}%"
        )

    print("-" * 115)

    # 전체 요약
    total_old = sum(r["old_tokens"] for r in results)
    total_new = sum(r["new_tokens"] for r in results)
    total_saved = total_old - total_new
    avg_rate = sum(r["saved_rate"] for r in results) / len(results) if results else 0
    avg_comments = sum(r["comments"] for r in results) / len(results) if results else 0
    avg_rounds = sum(r["rounds"] for r in results) / len(results) if results else 0

    total_sign = "+" if total_saved >= 0 else ""
    print(
        f"{'전체':>6} | {avg_comments:>4.1f} | {'':>4} | {avg_rounds:>5.1f} | "
        f"{'':>5} | {'':>6} | "
        f"{total_old:>10,} | {total_new:>10,} | "
        f"{total_sign}{total_saved:>9,} | {avg_rate:>6.1f}%"
    )
    print("=" * 115)
    print()
    print(f"측정 PR 수: {len(results)}")
    print(f"평균 라운드 수: {avg_rounds:.1f}")
    print(f"평균 절약률: {avg_rate:.1f}%")
    print(f"총 절약 토큰: {total_saved:,}")
    print(f"토크나이저: tiktoken cl100k_base")


def main():
    parser = argparse.ArgumentParser(
        description="resolve-coderabbit-review 스킬 구버전/신버전 토큰 비용 비교 측정",
    )
    parser.add_argument(
        "pr_numbers",
        nargs="*",
        type=int,
        help="측정할 PR 번호 (여러 개 가능)",
    )
    parser.add_argument(
        "--file", "-f",
        type=str,
        help="PR 번호 목록 파일 (한 줄에 하나)",
    )
    parser.add_argument(
        "--json-output", "-o",
        type=str,
        help="결과를 JSON 파일로 저장",
    )
    parser.add_argument(
        "--window-seconds", "-w",
        type=int,
        default=300,
        help="라운드 클러스터링 윈도우 (초). 기본 300초(5분).",
    )
    parser.add_argument(
        "--repo-root",
        type=str,
        default=None,
        help="측정 대상 레포 루트 (기본: 현재 디렉토리). 파일 토큰 계산 기준 경로.",
    )

    args = parser.parse_args()

    if args.repo_root:
        global REPO_ROOT
        REPO_ROOT = Path(args.repo_root).resolve()

    if not (REPO_ROOT / ".git").exists():
        print(
            f"  ⚠️  {REPO_ROOT} 는 git 레포 루트가 아닙니다. "
            "측정 대상 저장소에서 실행하거나 --repo-root 를 지정하세요.",
            file=sys.stderr,
        )

    pr_numbers: list[int] = list(args.pr_numbers or [])

    if args.file:
        with open(args.file, encoding="utf-8") as f:
            for idx, line in enumerate(f, start=1):
                line = line.strip()
                if line and not line.startswith("#"):
                    try:
                        pr_numbers.append(int(line))
                    except ValueError:
                        print(
                            f"  ⚠️  무시됨: {args.file} Line {idx} ('{line}')",
                            file=sys.stderr,
                        )

    if not pr_numbers:
        parser.error("PR 번호를 하나 이상 지정하세요")

    print(f"측정 대상: {len(pr_numbers)}개 PR (라운드 윈도우: {args.window_seconds}초)")
    print()

    results: list[dict] = []
    for pr in pr_numbers:
        print(f"  측정 중: PR #{pr} ...", end=" ", flush=True)
        result = measure_pr(pr, args.window_seconds)
        if result:
            print(
                f"코멘트 {result['comments']}개, 라운드 {result['rounds']}, "
                f"절약률 {result['saved_rate']}%"
            )
            results.append(result)
        else:
            print("스킵")

    if results:
        print_results(results)

    if args.json_output and results:
        with open(args.json_output, "w") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
        print(f"\nJSON 저장: {args.json_output}")


if __name__ == "__main__":
    main()
