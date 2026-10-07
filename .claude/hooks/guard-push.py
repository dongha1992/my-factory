#!/usr/bin/env python3
"""PreToolUse(Bash): 워커는 push 금지. push는 팩토리 스크립트가 한다."""
import json, re, sys

def blocked(cmd):
    return re.search(r"\bgit(\s+(-[Cc]\s+\S+|--?\S+))*\s+push\b", cmd) is not None

if __name__ == "__main__":
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    if blocked(cmd):
        print("차단됨: 워커는 git push 금지 (push는 factory.sh가 한다)", file=sys.stderr)
        sys.exit(2)
