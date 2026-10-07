#!/usr/bin/env python3
"""PreToolUse(Bash): workers never push; the factory script does."""
import json, re, sys

def blocked(cmd):
    return re.search(r"\bgit(\s+(-[Cc]\s+\S+|--?\S+))*\s+push\b", cmd) is not None

if __name__ == "__main__":
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    if blocked(cmd):
        print("blocked: workers must not git push (factory.sh pushes)", file=sys.stderr)
        sys.exit(2)
