#!/usr/bin/env bash
# 1회 실행: sync(머지된 PR -> Done) -> build(Ready -> QA) -> qa(QA -> Review).
# Review는 사람이 PR을 머지하는 단계다. DRY_RUN=1 이면 레인별 카드 목록만 출력한다.
set -euo pipefail
cd "$(dirname "$0")"
source .factory.env
READY=${READY:-Todo}; BUILDING=${BUILDING:-In Progress}; QA=${QA:-QA}
REVIEW=${REVIEW:-Review}; BLOCKED=${BLOCKED:-Blocked}; DONE=${DONE:-Done}
mkdir -p logs

pid=$(gh project view "$PROJECT" --owner "$OWNER" --format json -q .id)
fields=$(gh project field-list "$PROJECT" --owner "$OWNER" --format json)
fid=$(jq -r '.fields[]|select(.name=="Status").id' <<<"$fields")
opt() { jq -r --arg n "$1" '.fields[]|select(.name=="Status").options[]|select(.name==$n).id' <<<"$fields"; }
move() { gh project item-edit --project-id "$pid" --id "$1" --field-id "$fid" --single-select-option-id "$(opt "$2")" >/dev/null; }
# 해당 컬럼의 이슈 카드를 "번호 카드id" 줄로 출력
cards() { gh project item-list "$PROJECT" --owner "$OWNER" --format json -L 100 |
  jq -r --arg s "$1" '.items[]|select(.status==$s and .content.type=="Issue")|"\(.content.number) \(.id)"'; }
pr_of() { gh pr list --head "factory/issue-$1" --state all --json number,state -q '.[0]|"\(.number) \(.state)"'; }
title_of() { gh issue view "$1" --json title -q .title; }

# Review 카드의 PR이 머지됐으면 Done, 머지 없이 닫혔으면 Blocked
sync() {
  while read -r n id; do
    read -r _ state <<<"$(pr_of "$n")"
    case "$state" in
      MERGED) move "$id" "$DONE"; echo "#$n 머지됨 -> $DONE" ;;
      CLOSED) move "$id" "$BLOCKED"; echo "#$n PR 닫힘 -> $BLOCKED" ;;
    esac
  done <<<"$(cards "$REVIEW")"
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
      move "$id" "$REVIEW"
    else
      gh pr comment "$pr" --body "[QA] ❌ 실패 또는 판정 불가"$'\n\n'"$out" >/dev/null
      move "$id" "$BLOCKED"
    fi
  done <<<"$(cards "$QA")"
}

if [ -n "${DRY_RUN:-}" ]; then
  for s in "$READY" "$QA" "$REVIEW"; do echo "[$s]"; cards "$s"; done
  exit 0
fi
sync; build; qa
