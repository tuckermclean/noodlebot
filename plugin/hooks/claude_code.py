#!/usr/bin/env python3
"""Claude Code adapter for the role guard: a PreToolUse hook.

Why a plugin-level hook keyed on agent_type: Claude Code ignores the `hooks`,
`mcpServers` and `permissionMode` frontmatter fields of agents shipped by a plugin
(https://code.claude.com/docs/en/sub-agents, "Choose the subagent scope"), and tells a
plugin to ship its hooks in hooks/hooks.json instead. Those apply whenever the plugin is
enabled, so this script runs for every Edit, Write, NotebookEdit and Bash call and acts
only when the hook input's `agent_type` is one of the plugin's agents
(`noodlebot:tester`, `noodlebot:implementer`, `noodlebot:reviewer`;
https://code.claude.com/docs/en/hooks, "Hook locations"). Any other session is allowed.

It reads the hook JSON on stdin, maps the agent to a role and the tool to a kind (Edit,
Write, NotebookEdit: write; Bash: shell; other tools are allowed), asks guard.py, and
turns a block into exit 2 with the reason on stderr; exit 0 allows. The repository root
is CLAUDE_PROJECT_DIR, else the input's cwd.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import guard  # noqa: E402

ROLES = {"noodlebot:tester": "tester", "noodlebot:implementer": "implementer",
         "noodlebot:reviewer": "reviewer"}


def main():
    try:
        data = json.load(sys.stdin)
        role = ROLES.get(data.get("agent_type"))
        if role is None:
            return 0
        root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
        tool, tin = data.get("tool_name"), data.get("tool_input") or {}
        if tool in ("Edit", "Write", "NotebookEdit"):
            p = tin.get("file_path") or tin.get("notebook_path")
            reason = guard.check(role, "write", root, [p] if p else [])
        elif tool == "Bash":
            reason = guard.check(role, "shell", root, command=tin.get("command") or "")
        else:
            return 0
    except Exception as e:  # a bug here must not block unrelated work
        print(f"noodlebot role guard: ignored internal error: {e!r}", file=sys.stderr)
        return 0
    if reason is not None:
        print(f"noodlebot role guard: {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
