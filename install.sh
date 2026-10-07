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
cp "$SRC/factory.sh" "$SRC/setup-board.sh" "$T/factory/"
cp "$SRC"/prompts/*.md "$T/factory/prompts/"
cp "$SRC/.factory.env.example" "$T/factory/"

# 2) 훅·스크립트·스킬·워크플로우 복사 (.claude/ 아래, 같은 이름은 덮어쓴다)
mkdir -p "$T/.claude"
cp -R "$SRC/.claude/hooks" "$SRC/.claude/bin" "$SRC/.claude/skills" "$SRC/.claude/workflows" "$T/.claude/"
find "$T/.claude" -name __pycache__ -prune -exec rm -rf {} +

# 3) settings.json 병합: 훅 command가 이미 있으면 건너뛰고, 기존 설정은 보존
s=$T/.claude/settings.json; [ -f "$s" ] || echo '{}' >"$s"
jq -s '.[0] as $t | .[1].hooks as $h | reduce ($h|to_entries[]) as $ev ($t;
  reduce $ev.value[] as $entry (.;
    if ([.hooks[$ev.key][]?.hooks[]?.command] | index($entry.hooks[0].command)) then . else .hooks[$ev.key] += [$entry] end))' \
  "$s" "$SRC/.claude/settings.json" >"$s.tmp" && mv "$s.tmp" "$s"

# 4) .gitignore
touch "$T/.gitignore"
for l in factory/.factory.env factory/logs/ factory/.worktrees/; do
  grep -qxF "$l" "$T/.gitignore" || echo "$l" >>"$T/.gitignore"
done

cat <<MSG
✅ 설치 완료: $T
다음 단계:
  1. gh auth refresh -s project            (project 권한)
  2. cp factory/.factory.env.example factory/.factory.env  후 OWNER 입력
  3. factory/setup-board.sh --new          (Project 생성·repo 연결·컬럼 8개 설정, PROJECT 자동 기록)
     이미 만든 Project를 쓰려면 PROJECT를 적고 factory/setup-board.sh
  4. 변경분(factory/, .claude/, .gitignore)을 main에 커밋·push  ← 워커가 이 훅을 받아야 한다
  5. DRY_RUN=1 factory/factory.sh  →  factory/factory.sh
MSG
