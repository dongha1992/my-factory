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
# PR 리포트: 댓글 하나를 제자리 갱신한다(표에 한 줄 추가 + "최근 상세" 교체). 반려 횟수도 이 표에서 센다
REPORT_MARK='<!-- factory:report -->'
report_c() { gh pr view "$1" --json comments -q '[.comments[]|select(.body|startswith("'"$REPORT_MARK"'"))]|last // empty'; }
report_body() { local c; c=$(report_c "$1"); jq -r '.body // ""' <<<"${c:-null}"; }
rounds() { report_body "$1" | grep -c "^| [0-9]* | $2 | ❌" || true; }
last_detail() { report_body "$1" | awk '/^### 최근 상세/{f=1;next} f'; }
report() { # <pr> <레인> <결과> <상세>
  local c body rows n new
  c=$(report_c "$1"); body=$(jq -r '.body // ""' <<<"${c:-null}")
  rows=$(grep '^| [0-9]' <<<"$body" || true); n=$(grep -c . <<<"$rows" || true)
  new=$(printf '%s\n## 🏭 Factory 리포트\n\n| # | 레인 | 결과 |\n|---|---|---|\n%s| %d | %s | %s |\n\n### 최근 상세 (%s)\n%s\n' \
    "$REPORT_MARK" "${rows:+$rows$'\n'}" $((n+1)) "$2" "$3" "$2" "$4")
  if [ -n "$c" ]; then
    local url; url=$(jq -r '.url // ""' <<<"$c")
    gh api -X PATCH "repos/{owner}/{repo}/issues/comments/${url##*issuecomment-}" -f body="$new" >/dev/null
  else gh pr comment "$1" --body "$new" >/dev/null; fi
}
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
          r=$(rounds "$pr" Sync)
          if [ "$r" -lt "$MAX_REWORK" ]; then
            report "$pr" Sync "❌ main 충돌 → Rework ($((r+1))/$MAX_REWORK)" "main과 충돌한다. \`git merge origin/main\`으로 병합해 충돌을 해결하고 커밋해라."
            move "$id" "$REWORK"; echo "#$n 충돌 -> $REWORK"
          else
            report "$pr" Sync "⛔ Blocked (충돌 해결 ${MAX_REWORK}회 초과)" "사람이 main을 병합해 충돌을 풀어 주세요."
            move "$id" "$BLOCKED"; echo "#$n 충돌 -> $BLOCKED"
          fi ;;
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

$issue" --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Glob,Grep,Bash" </dev/null \
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

# 머지 위험도: 바뀐 경로로 결정적으로 계산한다 (단방향 문 = 되돌리기 어려운 경로, 폭발 반경 = 파일 수)
risk_of() {
  local files count door blast advice
  files=$(git diff --name-only "origin/main...origin/factory/issue-$1")
  count=$(grep -c . <<<"$files" || true)
  if grep -Eiq '(^|/)\.env|secret|\.github/|migrat|\.sql$|dockerfile|deploy' <<<"$files"; then door="단방향 문 (시크릿·CI·마이그레이션·배포 경로 포함)"; else door="양방향 문"; fi
  if [ "$count" -le 3 ]; then blast="국소(${count}개 파일)"; elif [ "$count" -le 10 ]; then blast="기능 단위(${count}개 파일)"; else blast="광범위(${count}개 파일)"; fi
  case "$door/$blast" in 양방향*/국소*) advice="훑어보고 머지" ;; *) advice="꼼꼼히 리뷰" ;; esac
  printf '**머지 위험도**: %s · 폭발 반경 %s → %s\n되돌리기: PR revert' "$door" "$blast" "$advice"
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
    # 결정적 게이트: TEST_CMD가 있으면 QA 워커 전에 종료 코드만 본다(토큰 0). 실패는 Rework, 반복되면 Blocked
    if [ -n "${TEST_CMD:-}" ] && ! (cd "$wt" && bash -c "$TEST_CMD") >"logs/check-$n.log" 2>&1 </dev/null; then
      git worktree remove --force "$wt"
      fails=$(rounds "$pr" Check)
      if [ "$fails" -lt "$MAX_REWORK" ]; then
        report "$pr" Check "❌ 테스트 실패 ($((fails+1))/$MAX_REWORK)" "$(tail -n 30 "logs/check-$n.log")"
        move "$id" "$REWORK"
      else
        report "$pr" Check "⛔ Blocked (테스트 실패 ${MAX_REWORK}회 초과)" "로그: logs/check-$n.log"
        move "$id" "$BLOCKED"
      fi
      continue
    fi
    issue=$(gh issue view "$n" --json title,body -q '"# \(.title)\n\n\(.body)"')
    extra=""   # 리뷰어가 [qa]로 되돌렸다면 그 요청을 QA에 전달한다
    if report_body "$pr" | grep '^| [0-9]' | tail -n1 | grep -q 'QA 재검증'; then
      extra=$'\n\n## 리뷰어가 요청한 추가 검증\n'"$(last_detail "$pr")"
    fi
    out=$(cd "$wt" && claude -p "$(cat ../../prompts/qa.md)

$issue$extra" --allowedTools "Read,Glob,Grep,Bash" </dev/null 2>&1) || true
    echo "$out" >"logs/qa-$n.log"
    git worktree remove --force "$wt"
    verdict=$(tail -n1 <<<"$out" | tr -d '[:space:]*`'); r=$(rounds "$pr" QA)
    if [ "$verdict" = "QA:PASS" ]; then
      report "$pr" QA "✅ 통과" "$out"
      move "$id" "$AI_REVIEW"
    elif [ "$verdict" = "QA:FAIL" ] && [ "$r" -lt "$MAX_REWORK" ]; then
      report "$pr" QA "❌ 실패 → Rework ($((r+1))/$MAX_REWORK)" "$out"
      move "$id" "$REWORK"
    else
      report "$pr" QA "⛔ Blocked (판정 불가 또는 실패 ${MAX_REWORK}회 초과)" "$out"
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

$issue" --allowedTools "Read,Glob,Grep,Bash" </dev/null 2>&1) || true
    echo "$out" >"logs/review-$n.log"
    git worktree remove --force "$wt"
    verdict=$(tail -n1 <<<"$out" | tr -d '[:space:]*`')
    tries=$(rounds "$pr" "AI Review")
    if [ "$verdict" = "REVIEW:APPROVE" ]; then
      report "$pr" "AI Review" "✅ 승인" "$out"$'\n\n'"$(risk_of "$n")"
      move "$id" "$REVIEW"
    elif [ "$verdict" = "REVIEW:CHANGES" ] && [ "$tries" -lt "$MAX_REWORK" ]; then
      # 반려 라우팅: [builder] 지적이 하나라도 있으면 Rework, [qa]만 있으면 코드 수정 없이 QA 재검증
      if grep -q '\[builder\]' <<<"$out" || ! grep -q '\[qa\]' <<<"$out"; then dest=$REWORK; lane=Rework; else dest=$QA; lane="QA 재검증"; fi
      report "$pr" "AI Review" "❌ $lane 요청 ($((tries+1))/$MAX_REWORK)" "$out"
      move "$id" "$dest"
    else
      report "$pr" "AI Review" "⛔ Blocked (판정 불가 또는 반려 ${MAX_REWORK}회 초과)" "$out"
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
    feedback=$(last_detail "$pr")
    (cd "$wt" && claude -p "$(cat ../../prompts/rework.md)

$issue

## 리뷰 지적
$feedback" --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Glob,Grep,Bash" </dev/null \
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
