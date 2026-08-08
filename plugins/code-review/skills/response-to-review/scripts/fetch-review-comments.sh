#!/bin/bash
# PR 인라인 리뷰 스레드 수집 스크립트 (토큰 최적화 버전)
# 사용법: ./fetch-review-comments.sh <pr_number> [repo]
# 예시: ./fetch-review-comments.sh 5665 whatap/whatap-front
#
# REVIEW_AUTHOR 환경변수로 루트 코멘트 작성자를 필터링합니다 (login prefix 매칭):
# - 미설정 또는 "any": 모든 작성자의 스레드 수집 (사람 리뷰어 포함 — 범용 기본값)
# - REVIEW_AUTHOR=coderabbitai: CodeRabbit 스레드만
# - REVIEW_AUTHOR=copilot: Copilot 스레드만
#
# 토큰 절약을 위해 body에서 불필요한 섹션 제거 (자동 리뷰어가 붙이는 것들):
# - <details>🧩 Analysis chain</details> - CodeRabbit 내부 분석 로그
# - <details>🤖 Prompt for AI Agents</details> - AI 에이전트용 지침
# - <!-- ... --> - HTML 주석
#
# resolved된 코멘트는 자동으로 skip됩니다.
# INCLUDE_RESOLVED=1 환경변수로 resolved 포함 가능 (측정/벤치마크용, measure_multi.py가 사용).
#
# 출력 필드:
# - id, path, line, body, created_at: 기존 필드 (measure_multi.py 호환 — line은 null이면 0)
# - author: 루트 코멘트 작성자 login (리뷰어 유형 판별용 — 봇/사람)
# - thread_id: 리뷰 스레드 GraphQL node ID (스레드 resolve 처리용)
# - is_outdated: 코드 변경으로 스레드가 outdated 되었는지 여부
# - original_line, start_line: outdated/멀티라인 코멘트의 원 위치 (없으면 null)
# - reply_count: 루트 코멘트 이후 답글 수 (이미 반박/답변한 스레드 구분용)
# - last_reply_author: 마지막 답글 작성자 login (답글 없으면 null)
# - fix_marker: 이전 실행이 남긴 수정 완료 마커 {commit, at}. 없으면 null
#     (수정 완료 댓글의 <!-- response-to-review:fixed commit=... --> 를 파싱.
#      구버전 마커 <!-- resolve-coderabbit-review:fixed ... --> 도 인식한다)
# - reviewer_reply_after_fix: 마커 이후 루트 작성자(리뷰어)가 남긴 마지막 답글 본문 (없으면 null)
#     → 단계 2.5에서 "승인 vs 재지적" 판정에 사용. 최대 1200자로 절단.

set -euo pipefail

# 의존성 확인
for cmd in gh jq perl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '${cmd}' not found in PATH" >&2
    exit 1
  fi
done

PR_NUMBER="${1:?Error: PR number is required}"
REPO="${2:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo '')}"

if [[ -z "$REPO" ]]; then
  echo "Error: Could not determine repository. Please provide as second argument." >&2
  exit 1
fi

# owner/repo 분리
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

# INCLUDE_RESOLVED 정규화 (1이 아니면 모두 0)
if [[ "${INCLUDE_RESOLVED:-0}" == "1" ]]; then
  INCLUDE_RESOLVED=1
else
  INCLUDE_RESOLVED=0
fi

# 작성자 필터 정규화 — 미설정이면 모든 작성자 수집
REVIEW_AUTHOR="${REVIEW_AUTHOR:-any}"

# PR 상태 확인 — PR이 없거나 접근 불가면 즉시 실패
# (gh 버전에 따라 --json merged 필드가 없으므로 state/mergedAt 사용)
if ! PR_STATE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state,mergedAt 2>&1); then
  echo "Error: Could not fetch PR #${PR_NUMBER} from ${REPO}: ${PR_STATE}" >&2
  exit 1
fi
STATE=$(echo "$PR_STATE" | jq -r '.state')
MERGED_AT=$(echo "$PR_STATE" | jq -r '.mergedAt // empty')

if [[ "$STATE" == "MERGED" ]] || [[ -n "$MERGED_AT" ]]; then
  echo "⚠️  Warning: PR #${PR_NUMBER} is MERGED. Comments can be analyzed but rebuttals cannot be posted." >&2
elif [[ "$STATE" == "CLOSED" ]]; then
  echo "⚠️  Warning: PR #${PR_NUMBER} is CLOSED. Comments can be analyzed but rebuttals may not be meaningful." >&2
fi

# body 가공 함수 - 불필요한 섹션 제거
process_body() {
  local body="$1"
  echo "$body" | \
    # Analysis chain 섹션 제거 (멀티라인)
    perl -0pe 's/<details>\s*<summary>🧩 Analysis chain<\/summary>.*?<\/details>//gs' | \
    # Prompt for AI Agents 섹션 제거 (멀티라인)
    perl -0pe 's/<details>\s*<summary>🤖 Prompt for AI Agents<\/summary>.*?<\/details>//gs' | \
    # Committable suggestion 섹션 제거
    perl -0pe 's/<!-- suggestion_start -->.*?<!-- suggestion_end -->//gs' | \
    # HTML 주석 제거 (>를 포함하는 주석도 처리, 멀티라인 포함)
    perl -0pe 's/<!--.*?-->//gs' | \
    # 연속 빈 줄 정리
    cat -s | \
    # 앞뒤 공백 제거
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# GraphQL로 리뷰 스레드 조회 (isResolved/isOutdated + 페이지네이션)
# comments: 스레드의 전체 코멘트. nodes[0] = 루트(분석 대상), 나머지 = 답글.
#   답글 본문이 필요한 이유 — 이전 실행이 남긴 수정 완료 마커와 그 이후 CodeRabbit
#   응답을 찾아 단계 2.5(스레드 정리)에서 resolve 여부를 판정하기 위함.
#   답글 본문은 로컬 jq 처리에만 쓰이고, 출력에는 필요한 1건만 절단해서 실린다.
GRAPHQL_QUERY='
query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          isOutdated
          line
          originalLine
          startLine
          comments(first: 100) {
            totalCount
            nodes {
              databaseId
              body
              path
              line
              createdAt
              author {
                login
              }
            }
          }
        }
      }
    }
  }
}'

run_graphql() {
  gh api graphql \
    -f query="$GRAPHQL_QUERY" \
    -F owner="$OWNER" \
    -F repo="$REPO_NAME" \
    -F pr="$PR_NUMBER" \
    "$@" 2>&1
}

# 페이지네이션 루프 — 100개 초과 스레드도 모두 수집
ALL_NODES='[]'
CURSOR=''
while :; do
  if [[ -n "$CURSOR" ]]; then
    if ! RAW_RESPONSE=$(run_graphql -f cursor="$CURSOR"); then
      echo "Error: GraphQL query failed for PR #${PR_NUMBER}: ${RAW_RESPONSE}" >&2
      exit 1
    fi
  else
    if ! RAW_RESPONSE=$(run_graphql); then
      echo "Error: GraphQL query failed for PR #${PR_NUMBER}: ${RAW_RESPONSE}" >&2
      exit 1
    fi
  fi

  THREADS=$(echo "$RAW_RESPONSE" | jq '.data.repository.pullRequest.reviewThreads // empty')
  if [[ -z "$THREADS" ]]; then
    echo "Error: Unexpected GraphQL response for PR #${PR_NUMBER}: ${RAW_RESPONSE}" >&2
    exit 1
  fi

  PAGE_NODES=$(echo "$THREADS" | jq '.nodes // []')
  ALL_NODES=$(jq -n --argjson a "$ALL_NODES" --argjson b "$PAGE_NODES" '$a + $b')

  HAS_NEXT=$(echo "$THREADS" | jq -r '.pageInfo.hasNextPage')
  if [[ "$HAS_NEXT" != "true" ]]; then
    break
  fi
  CURSOR=$(echo "$THREADS" | jq -r '.pageInfo.endCursor')
done

# 리뷰 코멘트 필터링
# 기본: resolved가 아닌 것만 (실 사용)
# INCLUDE_RESOLVED=1: 측정/벤치마크용으로 resolved 포함
# 작성자 매칭은 REST의 "coderabbitai[bot]" 표기와도 호환되도록 startswith 사용
RAW_COMMENTS=$(echo "$ALL_NODES" | jq --argjson includeResolved "$INCLUDE_RESOLVED" --arg author "$REVIEW_AUTHOR" '
  def author_matches($login): $author == "any" or ($login != null and ($login | startswith($author)));
[
  .[]
  | select($includeResolved == 1 or .isResolved == false)
  | . as $thread
  | (.comments.nodes // []) as $all
  | ($all[0] // null) as $root
  | select($root != null)
  | select(author_matches($root.author.login // null))
  | (($root.author.login // "") | sub("\\[bot\\]$"; "")) as $rootAuthorBase
  | ($all[1:]) as $replies
  # 이전 실행이 남긴 수정 완료 마커 중 가장 최근 것 (index 포함). 구버전 마커도 인식한다.
  | ([
      $replies
      | to_entries[]
      | select(.value.body != null and (.value.body | test("<!-- (response-to-review|resolve-coderabbit-review):fixed")))
    ] | last) as $fix
  | {
      id: $root.databaseId,
      path: $root.path,
      line: ($root.line // 0),
      body: $root.body,
      created_at: $root.createdAt,
      author: ($root.author.login // null),
      thread_id: $thread.id,
      is_outdated: $thread.isOutdated,
      original_line: $thread.originalLine,
      start_line: $thread.startLine,
      reply_count: ($thread.comments.totalCount - 1),
      # 답글 100개를 초과하는 스레드에서는 100번째 답글 기준 (실사용상 도달하지 않음)
      last_reply_author: (
        if $thread.comments.totalCount > 1
        then ($all[-1].author.login // null)
        else null
        end
      ),
      fix_marker: (
        if $fix == null then null
        else {
          commit: ([$fix.value.body | capture("(?:response-to-review|resolve-coderabbit-review):fixed commit=(?<c>[^\\s>]+)")] | first | .c),
          at: $fix.value.createdAt
        }
        end
      ),
      # 마커 이후 "이 스레드를 연 리뷰어"가 남긴 마지막 답글 — 승인/재지적 판정용.
      # 루트 작성자가 없으면(계정 삭제 등) 매칭 불가로 null.
      reviewer_reply_after_fix: (
        if $fix == null or $rootAuthorBase == "" then null
        else (
          [
            $replies[($fix.key + 1):][]
            | select(.author != null and (.author.login | startswith($rootAuthorBase)))
          ]
          | last
          | if . == null then null else (.body[0:1200]) end
        )
        end
      )
    }
]')

# resolved된 코멘트 수 계산 (정보 출력용)
RESOLVED_COUNT=$(echo "$ALL_NODES" | jq --arg author "$REVIEW_AUTHOR" '
  def author_matches($login): $author == "any" or ($login != null and ($login | startswith($author)));
[
  .[]
  | select(.isResolved == true)
  | .comments.nodes[0]
  | select(. != null)
  | select(author_matches(.author.login // null))
] | length')

TOTAL_COUNT=$(echo "$ALL_NODES" | jq --arg author "$REVIEW_AUTHOR" '
  def author_matches($login): $author == "any" or ($login != null and ($login | startswith($author)));
[
  .[]
  | .comments.nodes[0]
  | select(. != null)
  | select(author_matches(.author.login // null))
] | length')

if [[ "$RESOLVED_COUNT" -gt 0 ]]; then
  echo "ℹ️  Skipped ${RESOLVED_COUNT}/${TOTAL_COUNT} resolved comments" >&2
fi

# 코멘트가 없으면 빈 배열 출력
if [[ "$RAW_COMMENTS" == "[]" ]] || [[ "$RAW_COMMENTS" == "null" ]]; then
  echo "[]"
  exit 0
fi

# 각 코멘트의 body 가공 (그 외 필드는 그대로 유지)
# reviewer_reply_after_fix도 같은 방식으로 가공 — 마커 파싱은 이미 끝났으므로
# HTML 주석을 제거해도 안전하다.
PROCESSED_COMMENTS=$(echo "$RAW_COMMENTS" | jq -c '.[]' | while read -r comment; do
  body=$(echo "$comment" | jq -r '.body')
  processed_body=$(process_body "$body")

  reply=$(echo "$comment" | jq -r '.reviewer_reply_after_fix // empty')
  if [[ -n "$reply" ]]; then
    processed_reply=$(process_body "$reply")
    echo "$comment" | jq --arg body "$processed_body" --arg reply "$processed_reply" \
      '.body = $body | .reviewer_reply_after_fix = $reply'
  else
    echo "$comment" | jq --arg body "$processed_body" '.body = $body'
  fi
done | jq -s '.')

echo "$PROCESSED_COMMENTS"
