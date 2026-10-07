#!/usr/bin/env bash
# 오프라인 테스트: 가짜 gh/claude로 factory.sh의 레인 이동을 검증한다 (네트워크·토큰 불필요).
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 가짜 origin + factory/issue-1 브랜치가 있는 작업 repo
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/w" 2>/dev/null; cd "$T/w"
git config user.email t@t; git config user.name t
echo hi > README.md; git add -A; git commit -qm init; git branch -M main
if [ -n "${SUBDIR:-}" ]; then "$SRC/install.sh" "$T/w" >/dev/null; D=factory; else cp -r "$SRC/factory.sh" "$SRC/prompts" . ; D=.; fi
printf 'OWNER=o\nPROJECT=1\n' > $D/.factory.env
git add -A; git commit -qm setup; git push -q origin main
git checkout -qb factory/issue-1; echo feat >> README.md; git commit -qam feat; git push -q origin factory/issue-1
git checkout -q main

export PATH="$SRC/tests/stubs:$PATH" STUB_LOG="$T/log"
# 사용법: run <시작 컬럼> -> 이동 기록(옵션 id만) 한 줄로 출력
run() { : > "$STUB_LOG.moves"; STUB_STATUS="$1" $D/factory.sh >/dev/null 2>&1 || true
        tr '\n' ',' < "$STUB_LOG.moves" ; }
check() { [ "$2" = "$3" ] || { echo "FAIL $1: 기대 [$2] 실제 [$3]"; exit 1; }; echo "ok  $1"; }

check "QA 통과 -> AI Review -> 승인 -> Review" "AI Review,Review," "$(STUB_QA=PASS STUB_REVIEW=APPROVE run QA)"
check "QA 통과 -> AI Review -> 반려 -> Rework"  "AI Review,Rework," "$(STUB_QA=PASS STUB_REVIEW=CHANGES run QA)"
check "QA 실패 -> Rework"                       "Rework," "$(STUB_QA=FAIL run QA)"
check "QA 실패 3회째 -> Blocked" "Blocked," "$(STUB_QA=FAIL STUB_COMMENTS='{"body":"<!-- factory:report -->\n| 1 | QA | ❌ a |\n| 2 | QA | ❌ b |"}' run QA)"
check "QA 판정 불가(마지막 줄 이상) -> Blocked"  "Blocked," "$(STUB_QA=MAYBE run QA)"
check "리뷰 반려 3회째 -> Blocked" "Blocked," "$(STUB_REVIEW=CHANGES STUB_COMMENTS='{"body":"<!-- factory:report -->\n| 1 | AI Review | ❌ a |\n| 2 | AI Review | ❌ b |"}' run "AI Review")"
check "Rework 수정 커밋 -> QA(다시 QA부터 흐름)" "QA,AI Review,Review," "$(run Rework)"
check "Rework 커밋 없음 -> Blocked"            "Blocked," "$(STUB_NO_COMMIT=1 run Rework)"
check "리뷰 [builder] 지적 -> Rework"  "AI Review,Rework," "$(STUB_QA=PASS STUB_REVIEW=CHANGES STUB_FINDING='[builder] a.sh:1 — 고쳐' run QA)"
check "리뷰 [qa]만 지적 -> QA 재검증"  "AI Review,QA," "$(STUB_QA=PASS STUB_REVIEW=CHANGES STUB_FINDING='[qa] a.sh:1 — 테스트 증거' run QA)"
check "main 충돌 -> Rework -> (병합 커밋) QA부터 다시" "Rework,QA,AI Review,Review," "$(STUB_PR_CONFLICT=1 run QA)"
check "main 충돌 3회째 -> Blocked" "Blocked," "$(STUB_PR_CONFLICT=1 STUB_COMMENTS='{"body":"<!-- factory:report -->\n| 1 | Sync | ❌ a |\n| 2 | Sync | ❌ b |"}' run QA)"
check "TEST_CMD 실패 -> Rework (QA 워커 안 부름)" "Rework," "$(TEST_CMD=false run QA)"
check "TEST_CMD 3회째 실패 -> Blocked" "Blocked," "$(TEST_CMD=false STUB_COMMENTS='{"body":"<!-- factory:report -->\n| 1 | Check | ❌ a |\n| 2 | Check | ❌ b |"}' run QA)"
check "TEST_CMD 통과 -> 기존 QA 흐름" "AI Review,Review," "$(TEST_CMD=true STUB_QA=PASS run QA)"
: > "$STUB_LOG"; STUB_QA=PASS STUB_REVIEW=APPROVE run QA >/dev/null
check "승인 댓글에 위험도(양방향·국소)" "1" "$(grep -c '머지 위험도.*양방향 문 · 폭발 반경 국소(1개 파일) → 훑어보고 머지' "$STUB_LOG")"
: > "$STUB_LOG"; STUB_QA=PASS STUB_REVIEW=APPROVE STUB_COMMENTS='{"url":"https://x/pull/9#issuecomment-555","body":"<!-- factory:report -->\n| 1 | QA | ✅ 통과 |"}' run QA >/dev/null
check "리포트 댓글은 새로 달지 않고 제자리 갱신(PATCH)" "2/0" "$(grep -c 'issues/comments/555' "$STUB_LOG")/$(grep -c 'pr comment' "$STUB_LOG")"
check "포인트 부족이면 아무것도 안 함"            "" "$(STUB_QUOTA=10 run QA)"
