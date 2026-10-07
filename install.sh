#!/usr/bin/env bash
# 사용법: ./install.sh <대상 프로젝트 경로>
# 대상 프로젝트에 팩토리를 설치한다. 여러 번 실행해도 안전하다(.factory.env와 기존 설정은 건드리지 않는다).
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
T=$(cd "${1:?사용법: ./install.sh <대상 프로젝트 경로>}" && pwd)

git -C "$T" rev-parse --verify -q main >/dev/null ||
  { echo "대상 repo에 main 브랜치가 없습니다 (팩토리는 main 기준으로 동작합니다)"; exit 1; }
command -v jq >/dev/null || { echo "jq가 필요합니다"; exit 1; }

# 1) 팩토리 본체: <대상>/factory/
mkdir -p "$T/factory/prompts"
cp "$SRC/factory.sh" "$T/factory/"
cp "$SRC"/prompts/*.md "$T/factory/prompts/"
cp "$SRC/.factory.env.example" "$T/factory/"

# 2) push 가드 훅 + settings.json 병합 (이미 있으면 건너뜀)
mkdir -p "$T/.claude/hooks"
cp "$SRC/.claude/hooks/guard-push.py" "$T/.claude/hooks/"
s=$T/.claude/settings.json; [ -f "$s" ] || echo '{}' >"$s"
jq 'if ([.hooks.PreToolUse[]?.hooks[]?.command]|any(contains("guard-push.py"))) then . else
  .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"python3 \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-push.py\""}]}] end' "$s" >"$s.tmp" && mv "$s.tmp" "$s"

# 3) .gitignore
touch "$T/.gitignore"
for l in factory/.factory.env factory/logs/ factory/.worktrees/; do
  grep -qxF "$l" "$T/.gitignore" || echo "$l" >>"$T/.gitignore"
done

cat <<MSG
✅ 설치 완료: $T
다음 단계:
  1. gh auth refresh -s project            (project 권한)
  2. GitHub Project를 만들고 Status 컬럼을 Todo · In Progress · QA · AI Review · Rework · Review · Blocked · Done 으로 맞춘다
  3. cp factory/.factory.env.example factory/.factory.env  후 OWNER, PROJECT 입력
  4. 변경분(factory/, .claude/, .gitignore)을 main에 커밋·push  ← 워커가 이 훅을 받아야 한다
  5. DRY_RUN=1 factory/factory.sh  →  factory/factory.sh
MSG
