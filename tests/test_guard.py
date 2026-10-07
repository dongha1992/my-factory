import sys; sys.path.insert(0, ".claude/hooks")
import importlib.util
s = importlib.util.spec_from_file_location("g", ".claude/hooks/guard-push.py"); g = importlib.util.module_from_spec(s); s.loader.exec_module(g)
assert g.blocked("git push origin main")
assert g.blocked("git -C x push -f")
assert not g.blocked("git commit -m 'push notes'")
assert not g.blocked("git status")
print("ok")
