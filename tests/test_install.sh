#!/usr/bin/env bash
# 오프라인 테스트: install.sh의 설치 결과·멱등성·기존 설정 보존을 확인한다.
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q -b main "$T/p"; cd "$T/p"; git config user.email t@t; git config user.name t
echo x > a; git add -A; git commit -qm i
mkdir .claude; echo '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"echo hi"}]}]}}' > .claude/settings.json
echo "keep" > .gitignore
ok() { echo "ok  $1"; }; bad() { echo "FAIL $1"; exit 1; }

"$SRC/install.sh" "$T/p" >/dev/null
[ -x factory/factory.sh ] && [ -f factory/prompts/qa.md ] && [ -f .claude/hooks/guard-push.py ] || bad "파일 설치"; ok "파일 설치"
[ "$(jq '[.hooks.PreToolUse[]|select(.hooks[0].command|contains("guard-push"))]|length' .claude/settings.json)" = 1 ] || bad "훅 등록"
jq -e '.permissions.allow[0]=="Bash(ls)" and (.hooks.PreToolUse|length)==2' .claude/settings.json >/dev/null || bad "기존 설정 보존"; ok "훅 등록 + 기존 설정 보존"

echo "OWNER=me" > factory/.factory.env
"$SRC/install.sh" "$T/p" >/dev/null
[ "$(jq '.hooks.PreToolUse|length' .claude/settings.json)" = 2 ] || bad "멱등성(훅 중복)"
[ "$(grep -c 'factory/logs/' .gitignore)" = 1 ] && head -1 .gitignore | grep -q keep || bad "멱등성(.gitignore)"
grep -q "OWNER=me" factory/.factory.env || bad ".factory.env 보존"; ok "재설치해도 중복 없음, .factory.env 보존"

git checkout -qb dev; git branch -D main -q
"$SRC/install.sh" "$T/p" >/dev/null 2>&1 && bad "main 없는 repo 거부" || ok "main 없는 repo 거부"
