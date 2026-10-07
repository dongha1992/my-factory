#!/usr/bin/env bash
# 보드 준비: Status 컬럼을 팩토리 레인 8개로 맞춘다.
#   ./setup-board.sh                 .factory.env의 PROJECT 보드를 맞춘다
#   ./setup-board.sh --new [제목]    새 Project를 만들고 repo에 연결한 뒤 PROJECT를 .factory.env에 기록한다
#   --force                          상태가 있는 카드가 있어도 진행 (컬럼 교체 시 그 카드들의 상태가 지워진다)
set -euo pipefail
cd "$(dirname "$0")"
[ -f .factory.env ] || cp .factory.env.example .factory.env
source .factory.env
[ "$OWNER" != "your-github-id" ] || { echo ".factory.env의 OWNER를 먼저 채우세요"; exit 1; }

new=""; force=""; title=""
for a in "$@"; do case "$a" in --new) new=1 ;; --force) force=1 ;; *) title=$a ;; esac; done

if [ -n "$new" ]; then
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)   # 먼저 확인해야 실패 시 빈 Project가 남지 않는다
  PROJECT=$(gh project create --owner "$OWNER" --title "${title:-software-factory}" --format json -q .number)
  gh project link "$PROJECT" --owner "$OWNER" --repo "$repo" >/dev/null
  sed -i.bak "s/^PROJECT=[0-9]*/PROJECT=$PROJECT/" .factory.env && rm -f .factory.env.bak
  echo "새 Project #$PROJECT 생성·연결"
fi

lanes=("Todo:GRAY" "In Progress:YELLOW" "QA:ORANGE" "AI Review:PURPLE" "Rework:PINK" "Review:BLUE" "Blocked:RED" "Done:GREEN")
want=$(printf '%s\n' "${lanes[@]%%:*}")

field=$(gh project field-list "$PROJECT" --owner "$OWNER" --format json |
  jq -c '.fields[]|select(.name=="Status")')
have=$(jq -r '.options[].name' <<<"$field")
[ "$have" = "$want" ] && { echo "컬럼이 이미 맞습니다 (Project #$PROJECT)"; exit 0; }

# 컬럼 교체는 옵션 id를 새로 만들어 기존 카드의 상태를 지운다
used=$(gh project item-list "$PROJECT" --owner "$OWNER" --format json -L 100 |
  jq '[.items[]|select(.status!=null and .status!="")]|length')
[ "$used" = 0 ] || [ -n "$force" ] ||
  { echo "상태가 있는 카드 ${used}장이 있어 중단합니다. 상태가 지워져도 되면 --force"; exit 1; }

opts=$(for l in "${lanes[@]}"; do printf '{name:"%s",color:%s,description:""},' "${l%%:*}" "${l##*:}"; done)
gh api graphql -f query="mutation{updateProjectV2Field(input:{fieldId:\"$(jq -r .id <<<"$field")\",singleSelectOptions:[${opts%,}]}){clientMutationId}}" >/dev/null
echo "컬럼 설정 완료 (Project #$PROJECT): ${want//$'\n'/ · }"
