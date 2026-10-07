#!/usr/bin/env bash
# 1회 실행: sync -> rework -> build -> qa -> ai_review. Review는 사람이 PR을 머지하는 단계다. DRY_RUN=1 이면 레인별 카드 목록만 출력한다.
set -euo pipefail
cd "$(dirname "$0")"
source .factory.env
READY=${READY:-Todo}; BUILDING=${BUILDING:-In Progress}; QA=${QA:-QA}
REVIEW=${REVIEW:-Review}; AI_REVIEW=${AI_REVIEW:-AI Review}; REWORK=${REWORK:-Rework}; MAX_REWORK=${MAX_REWORK:-2}; BLOCKED=${BLOCKED:-Blocked}; DONE=${DONE:-Done}
mkdir -p logs

# GraphQL 포인트가 부족하면 시작하지 않는다 (project 조회 한 번에도 수십 포인트가 든다)
left=$(gh api graphql -f query='{rateLimit{remaining}}' -q .data.rateLimit.remaining)
[ "$left" -ge 300 ] || { echo "GraphQL 포인트 부족($left). 한도가 초기화된 뒤 다시 실행하세요"; exit 75; }

pid=$(gh project view "$PROJECT" --owner "$OWNER" --format json -q .id)
fields=$(gh project field-list "$PROJECT" --owner "$OWNER" --format json)
fid=$(jq -r '.fields[]|select(.name=="Status").id' <<<"$fields")
opt() { jq -r --arg n "$1" '.fields[]|select(.name=="Status").options[]|select(.name==$n).id' <<<"$fields"; }
# 보드는 실행당 한 번만 읽고(ITEMS), 이동할 때 로컬 캐시도 같이 고친다
ITEMS=$(gh project item-list "$PROJECT" --owner "$OWNER" --format json -L 100)
move() {
  gh project item-edit --project-id "$pid" --id "$1" --field-id "$fid" --single-select-option-id "$(opt "$2")" >/dev/null
  ITEMS=$(jq --arg id "$1" --arg s "$2" '(.items[]|select(.id==$id)|.status)=$s' <<<"$ITEMS")
}
# 해당 컬럼의 이슈 카드를 "번호 카드id" 줄로 출력
cards() { jq -r --arg s "$1" '.items[]|select(.status==$s and .content.type=="Issue")|"\(.content.number) \(.id)"' <<<"$ITEMS"; }
# PR 목록도 한 번만 읽는다 (PR을 만든 뒤에는 refresh_prs)
refresh_prs() { PRS=$(gh pr list --state all --limit 100 --json number,state,mergeable,headRefName); }
pr_of() { jq -r --arg h "factory/issue-$1" 'map(select(.headRefName==$h))|.[0]|"\(.number) \(.state) \(.mergeable)"' <<<"$PRS"; }
title_of() { gh issue view "$1" --json title -q .title; }

# QA/Review 카드의 PR 상태 반영: 머지됨 -> Done, 머지 없이 닫힘 -> Blocked, main과 충돌 -> Blocked
sync() {
  for col in "$REVIEW" "$AI_REVIEW" "$QA"; do
    while read -r n id; do
      [ -z "$n" ] && continue
      read -r pr state mergeable <<<"$(pr_of "$n")"
      case "$state/$mergeable" in
        MERGED/*) move "$id" "$DONE"; echo "#$n 머지됨 -> $DONE" ;;
        CLOSED/*) move "$id" "$BLOCKED"; echo "#$n PR 닫힘 -> $BLOCKED" ;;
        OPEN/CONFLICTING)
          gh pr comment "$pr" --body "factory: main과 충돌해 Blocked로 옮겼습니다. main을 병합해 충돌을 푼 뒤 QA로 되돌려 주세요." >/dev/null
          move "$id" "$BLOCKED"; echo "#$n 충돌 -> $BLOCKED" ;;
      esac
    done <<<"$(cards "$col")"
  done
}

# Ready 이슈마다 worktree에서 구현시키고 PR을 연다
build() {
  while read -r n id; do
    [ -z "$n" ] && continue
    echo "== build #$n"
    move "$id" "$BUILDING"
    wt=.worktrees/issue-$n br=factory/issue-$n
    git worktree add -q "$wt" -b "$br" main
    issue=$(gh issue view "$n" --json title,body -q '"# \(.title)\n\n\(.body)"')
    (cd "$wt" && claude -p "$(cat ../../prompts/build.md)

$issue" --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
      >"../../logs/build-$n.log" 2>&1) || true
    if [ "$(git -C "$wt" rev-list --count main..HEAD)" -gt 0 ]; then
      git -C "$wt" push -q -u origin "$br"
      gh pr create --head "$br" --title "$(title_of "$n")" --body "Closes #$n" >/dev/null
      move "$id" "$QA"
    else
      gh issue comment "$n" --body "factory: 커밋이 만들어지지 않아 Blocked로 옮겼습니다. 이슈를 보강한 뒤 Ready로 되돌려 주세요. 로그: logs/build-$n.log" >/dev/null
      move "$id" "$BLOCKED"   # 사람이 이슈를 고친 뒤 Ready로 되돌려야 재시도된다
    fi
    git worktree remove --force "$wt"
  done <<<"$(cards "$READY")"
}

# QA 카드: PR 브랜치를 읽기 전용 워커가 검증. 마지막 줄이 `QA: PASS`일 때만 통과(그 외는 전부 실패)
qa() {
  git fetch -q origin
  while read -r n id; do
    [ -z "$n" ] && continue
    read -r pr _ <<<"$(pr_of "$n")"
    echo "== qa #$n (PR #$pr)"
    wt=.worktrees/qa-$n
    git worktree add -q --detach "$wt" "origin/factory/issue-$n"
    issue=$(gh issue view "$n" --json title,body -q '"# \(.title)\n\n\(.body)"')
    out=$(cd "$wt" && claude -p "$(cat ../../prompts/qa.md)

$issue" --allowedTools "Read,Glob,Grep,Bash" 2>&1) || true
    echo "$out" >"logs/qa-$n.log"
    git worktree remove --force "$wt"
    if [ "$(tail -n1 <<<"$out" | tr -d '[:space:]*`')" = "QA:PASS" ]; then
      gh pr comment "$pr" --body "[QA] ✅ 통과"$'\n\n'"$out" >/dev/null
      move "$id" "$AI_REVIEW"
    else
      gh pr comment "$pr" --body "[QA] ❌ 실패 또는 판정 불가"$'\n\n'"$out" >/dev/null
      move "$id" "$BLOCKED"
    fi
  done <<<"$(cards "$QA")"
}

# AI Review 카드: 읽기 전용 리뷰. APPROVE -> Review, CHANGES -> Rework(최대 MAX_REWORK회), 판정 불가 -> Blocked
ai_review() {
  git fetch -q origin
  while read -r n id; do
    [ -z "$n" ] && continue
    read -r pr _ <<<"$(pr_of "$n")"
    echo "== ai-review #$n (PR #$pr)"
    wt=.worktrees/rv-$n
    git worktree add -q --detach "$wt" "origin/factory/issue-$n"
    issue=$(gh issue view "$n" --json title,body -q '"# \(.title)\n\n\(.body)"')
    out=$(cd "$wt" && claude -p "$(cat ../../prompts/review.md)

$issue" --allowedTools "Read,Glob,Grep,Bash" 2>&1) || true
    echo "$out" >"logs/review-$n.log"
    git worktree remove --force "$wt"
    verdict=$(tail -n1 <<<"$out" | tr -d '[:space:]*`')
    tries=$(gh pr view "$pr" --json comments -q '[.comments[]|select(.body|startswith("[AI Review] ❌"))]|length')
    if [ "$verdict" = "REVIEW:APPROVE" ]; then
      gh pr comment "$pr" --body "[AI Review] ✅ 승인"$'\n\n'"$out" >/dev/null
      move "$id" "$REVIEW"
    elif [ "$verdict" = "REVIEW:CHANGES" ] && [ "$tries" -lt "$MAX_REWORK" ]; then
      gh pr comment "$pr" --body "[AI Review] ❌ 수정 요청 ($((tries+1))/$MAX_REWORK)"$'\n\n'"$out" >/dev/null
      move "$id" "$REWORK"
    else
      gh pr comment "$pr" --body "[AI Review] ⛔ Blocked (판정 불가 또는 반려 ${MAX_REWORK}회 초과)"$'\n\n'"$out" >/dev/null
      move "$id" "$BLOCKED"
    fi
  done <<<"$(cards "$AI_REVIEW")"
}

# Rework 카드: 마지막 리뷰 지적을 builder가 같은 브랜치에서 고치고 QA부터 다시 간다
rework() {
  git fetch -q origin
  while read -r n id; do
    [ -z "$n" ] && continue
    read -r pr _ <<<"$(pr_of "$n")"
    echo "== rework #$n (PR #$pr)"
    wt=.worktrees/rw-$n br=factory/issue-$n
    git worktree add -q -B "$br" "$wt" "origin/$br"
    issue=$(gh issue view "$n" --json title,body -q '"# \(.title)\n\n\(.body)"')
    feedback=$(gh pr view "$pr" --json comments -q '[.comments[]|select(.body|startswith("[AI Review] ❌"))]|last|.body')
    (cd "$wt" && claude -p "$(cat ../../prompts/rework.md)

$issue

## 리뷰 지적
$feedback" --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
      >"../../logs/rework-$n.log" 2>&1) || true
    if [ "$(git -C "$wt" rev-list --count "origin/$br"..HEAD)" -gt 0 ]; then
      git -C "$wt" push -q origin "HEAD:$br"
      move "$id" "$QA"
    else
      gh pr comment "$pr" --body "factory: 수정 커밋이 만들어지지 않아 Blocked로 옮겼습니다. 로그: logs/rework-$n.log" >/dev/null
      move "$id" "$BLOCKED"
    fi
    git worktree remove --force "$wt"
  done <<<"$(cards "$REWORK")"
}

if [ -n "${DRY_RUN:-}" ]; then
  for s in "$READY" "$QA" "$AI_REVIEW" "$REWORK" "$REVIEW"; do echo "[$s]"; cards "$s"; done
  exit 0
fi
refresh_prs; sync; rework; build; refresh_prs; qa; ai_review
