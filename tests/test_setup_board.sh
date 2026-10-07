#!/usr/bin/env bash
# 오프라인 테스트: setup-board.sh (가짜 gh 사용)
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/f"; cp "$SRC/setup-board.sh" "$SRC/.factory.env.example" "$T/f/"
export PATH="$SRC/tests/stubs:$PATH" STUB_LOG="$T/log"
reset() { : > "$STUB_LOG"; printf 'OWNER=o\nPROJECT=1\n' > "$T/f/.factory.env"; }
mutated() { grep -c updateProjectV2Field "$STUB_LOG" || true; }
check() { [ "$2" = "$3" ] || { echo "FAIL $1: 기대 [$2] 실제 [$3]"; exit 1; }; echo "ok  $1"; }
run() { "$T/f/setup-board.sh" "$@" >/dev/null 2>&1; }

reset; STUB_STATUS="" run; check "이미 맞으면 변경 없음" 0 "$(mutated)"
reset; STUB_OLD=1 STUB_STATUS="" run; check "옛 컬럼이면 교체" 1 "$(mutated)"
grep -q 'name:\\"AI Review\\"\|name:"AI Review"' "$STUB_LOG" && echo "ok  레인 8개 이름 전달" || { echo "FAIL 레인 이름"; exit 1; }
reset; STUB_OLD=1 STUB_STATUS=Todo run && { echo "FAIL 카드 있으면 중단"; exit 1; }; check "상태 있는 카드가 있으면 중단" 0 "$(mutated)"
reset; STUB_OLD=1 STUB_STATUS=Todo run --force; check "--force면 진행" 1 "$(mutated)"
reset; STUB_STATUS="" run --new "내 팩토리"; check "--new: PROJECT 기록" "PROJECT=7" "$(grep PROJECT "$T/f/.factory.env")"
grep -q "project link 7" "$STUB_LOG" && echo "ok  --new: repo 연결" || { echo "FAIL repo 연결"; exit 1; }
printf 'OWNER=your-github-id\nPROJECT=1\n' > "$T/f/.factory.env"; run && { echo "FAIL OWNER 미설정"; exit 1; }; echo "ok  OWNER 미설정이면 중단"
