#!/usr/bin/env bash
# One pass: every Ready issue -> claude -p in its own worktree -> PR -> Done.
# DRY_RUN=1 only lists the cards.
set -euo pipefail
cd "$(dirname "$0")"
source .factory.env
READY=${READY:-Todo}; BUILDING=${BUILDING:-In Progress}; DONE=${DONE:-Done}
mkdir -p logs

pid=$(gh project view "$PROJECT" --owner "$OWNER" --format json -q .id)
fields=$(gh project field-list "$PROJECT" --owner "$OWNER" --format json)
fid=$(jq -r '.fields[]|select(.name=="Status").id' <<<"$fields")
opt() { jq -r --arg n "$1" '.fields[]|select(.name=="Status").options[]|select(.name==$n).id' <<<"$fields"; }
move() { gh project item-edit --project-id "$pid" --id "$1" --field-id "$fid" --single-select-option-id "$(opt "$2")" >/dev/null; }

cards=$(gh project item-list "$PROJECT" --owner "$OWNER" --format json -L 100 |
  jq -r --arg s "$READY" '.items[]|select(.status==$s and .content.type=="Issue")|"\(.content.number) \(.id)"')

[ -z "$cards" ] && { echo "no Ready cards"; exit 0; }
[ -n "${DRY_RUN:-}" ] && { echo "$cards"; exit 0; }

while read -r n id; do
  echo "== #$n"
  move "$id" "$BUILDING"
  wt=.worktrees/issue-$n br=factory/issue-$n
  git worktree add -q "$wt" -b "$br" main
  issue=$(gh issue view "$n" --json title,body -q '"# \(.title)\n\n\(.body)"')
  (cd "$wt" && claude -p "$(cat ../../prompts/build.md)

$issue" --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
    >"../../logs/issue-$n.log" 2>&1) || true
  if [ "$(git -C "$wt" rev-list --count main..HEAD)" -gt 0 ]; then
    git -C "$wt" push -q -u origin "$br"
    gh pr create --head "$br" --title "$(gh issue view "$n" --json title -q .title)" \
      --body "Closes #$n"$'\n\nlog: logs/issue-'"$n"'.log' >/dev/null
    move "$id" "$DONE"
  else
    gh issue comment "$n" --body "factory: no commits produced, see logs/issue-$n.log" >/dev/null
    move "$id" "$READY"   # ponytail: no Blocked column; retried next pass, add one when this loops
  fi
  git worktree remove --force "$wt"
done <<<"$cards"
