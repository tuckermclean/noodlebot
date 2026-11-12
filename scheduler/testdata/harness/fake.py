"""The fake harness backend (S08, change 7): "runs" a session by replaying a scripted event list.

THE CONTRACT (S08 slice 1; scheduler/harness.test.sh checks it, scheduler/harnesses/claude_code.py and
scheduler/harness.py conform to it; the README in scheduler/harnesses/ documents it).

1. Backend lookup. scheduler/harness.py takes the backend name from $SCHED_HARNESS (unset or "claude-code":
   scheduler/harnesses/claude_code.py; "fake": this file; any other name: a message on stderr, exit 2).

2. A backend module exports these functions (this file is the model):
     NAME                                        the backend's name
     capabilities() -> list[str]                 the capabilities that are ON, from "usage" (usage readings),
                                                 "resume" (conversation resume), "bg-wait" (background-wait setting)
     skill_command(skill, args, shipped=False)   how a prompt names a skill; Claude Code: "/noodlebot:node B03", or
                                                 "/node B03" when shipped (the repository ships its own skill)
     matches(cmdline, unit) -> bool              cmdline is /proc/<pid>/cmdline with NULs turned into spaces; true
                                                 when the process is unit's session (see note 5)
     preflight() -> None | str                   None when the credential is usable, else the message (reads $HOME)
     start(worktree, state_dir, prompt, system_prompt, plugin) -> int     runs the session in the foreground; the raw
                                                 stream goes to this process's stdout (the loop redirects it to
                                                 <state_dir>/session.jsonl), events are appended to
                                                 <state_dir>/events.jsonl as the session runs; returns the exit code
     resume(worktree, state_dir, session_id, prompt) -> int               the same, for a resumed conversation; the
                                                 raw log and events.jsonl are appended to
     events(state_dir) -> list[dict]             the session's events; rebuilds <state_dir>/events.jsonl from
                                                 <state_dir>/session.jsonl (and session.stderr for "cutoff") when it is
                                                 missing or behind the raw log, then returns its parsed lines
   scheduler/harness.py re-exports each of them as a Python function of the same name (harness.capabilities() etc.;
   the test reads them with `import harness` and callable(getattr(harness, name))) and as a CLI subcommand, name with
   "_" written "-":
     harness.py start <worktree> <state-dir> <prompt> <system-prompt-file> <plugin>   exit code = the session's
     harness.py resume <worktree> <state-dir> <session-id> <prompt>                    exit code = the session's
     harness.py skill-command <skill> <args> [shipped]       prints the command
     harness.py matches <unit> <cmdline>                      exit 0 / 1
     harness.py preflight                                     exit 0, or exit 1 with the message on stderr
     harness.py events <state-dir>                            prints events.jsonl (rebuilt first when needed)
     harness.py capabilities                                  prints the capabilities that are on, one per line
   scheduler/run-session.sh <worktree> <state-dir> <prompt> [<session id>] keeps its arguments; with a session id it
   resumes with the prompt in <state-dir>/resume-prompt.md, else it starts with the system prompt in
   <state-dir>/unattended.md. It writes the exit code to <state-dir>/session.rc (atomically, no .tmp left behind).

3. events.jsonl: one JSON object per line, always with "t" (the raw line's "timestamp" string verbatim, else null;
   never the wall clock, so that a rebuild equals the live file) and "type":
     start        session            the session id of a system/init line (a resumed session has one more per resume)
     usage        status, reset, window, utilization, windows
                                     one per rate_limit_event; status/reset/window/utilization are the line's
                                     rate_limit_info.status / .resetsAt / .rateLimitType / .utilization (null when
                                     absent); windows maps each unifiedWindows name to {status, utilization, reset}
     tool         id, name, text, label, subagent, background, delay, desc
                                     one per tool_use block. text: the first line of input.description, else command,
                                     else path, else file_path, cut to 200 (null when none); label: the first line of
                                     description, command, file_path or skill, cut to 100 ("" when none); subagent: the
                                     line has a parent_tool_use_id; background: input.run_in_background is true and
                                     name is Bash or Agent; delay: input.delaySeconds of ScheduleWakeup, else null;
                                     desc: input.description (or "a subagent") of Agent/Task, else null
     tool_result  id, subagent, bg_id one per tool_result block; id is its tool_use_id; bg_id the background id in its
                                     content ("ID: <id>" or "agentId: <id>"), else null
     text         text, subagent     one per text block, whitespace collapsed, cut to 400
     result       subtype, text, cost, turns, limit
                                     text: result stripped (null when empty or not a string); cost: total_cost_usd
                                     when a finite number, else null; turns: num_turns when a non-negative int, else
                                     null; limit: result + " " + subtype matches /usage limit|rate limit|limit
                                     reached|hit your limit/i
     task_done    ids                [task_id, tool_use_id] of a system/task_notification, the ones that are set
     cutoff       (none)             last, once, when session.stderr says "background task(s) still running ... after
                                     the last turn ... stopping them" (t null)
     other        (none)             a well-formed JSON object line that gave no other event (so that the last event
                                     is the last line, as idle_by_limit reads it)
     garbled      (none)             a non-blank line that is no JSON object (a cut last line included): the last line
                                     is unknown. Blank lines give nothing.
   A line with several blocks gives several events, in order. Readers must not rely on more fields than listed;
   backends may add fields, tests compare the listed ones.

4. This fake's knobs (environment variables, set per test):
     FAKE_HARNESS_SCRIPT         file of events (JSON lines, as above) replayed by start (required to say anything)
     FAKE_HARNESS_RESUME_SCRIPT  the same for resume; defaults to FAKE_HARNESS_SCRIPT
     FAKE_HARNESS_RC             exit code of start (default 0); FAKE_HARNESS_RESUME_RC for resume (default: the same)
     FAKE_HARNESS_CAPS           comma list of capabilities that are on; unset: all three; set to "": none
     FAKE_HARNESS_PREFLIGHT      "fail": preflight reports a missing credential
     FAKE_HARNESS_LOG            file that gets one line per call: "start <state_dir> <prompt>" or
                                 "resume <state_dir> <session id> <prompt>"
   The fake replays each scripted event as one raw line on stdout too (its "raw log"), appends the events verbatim to
   events.jsonl, and returns the exit code. It reads no credential. Its events() has nothing to rebuild from and returns
   events.jsonl as it is.

5. matches: this fake matches run-session.sh's own command line only ("run-session.sh ... <unit>" at its end);
   Claude Code's also matches a bare "claude -p /node <unit>".
"""
import json
import os
import re
import sys

NAME = "fake"
ALL = ["usage", "resume", "bg-wait"]


def capabilities():
    v = os.environ.get("FAKE_HARNESS_CAPS")
    return list(ALL) if v is None else [c for c in v.split(",") if c]


def skill_command(skill, args, shipped=False):
    return ("/%s %s" if shipped else "/fake:%s %s") % (skill, args)


def matches(cmdline, unit):
    return re.search(r"run-session\.sh .* %s( |$)" % re.escape(unit), cmdline) is not None


def preflight():
    return "fake harness: no credential" if os.environ.get("FAKE_HARNESS_PREFLIGHT") == "fail" else None


def _log(*words):
    p = os.environ.get("FAKE_HARNESS_LOG")
    if p:
        with open(p, "a") as f:
            f.write(" ".join(words) + "\n")


def _replay(state_dir, script, rc):
    if script:
        with open(script) as src, open(os.path.join(state_dir, "events.jsonl"), "a") as out:
            for line in src:
                if line.strip():
                    sys.stdout.write(line.rstrip("\n") + "\n")
                    out.write(line.rstrip("\n") + "\n")
        sys.stdout.flush()
    return int(rc)


def start(worktree, state_dir, prompt, system_prompt, plugin):
    _log("start", state_dir, prompt)
    return _replay(state_dir, os.environ.get("FAKE_HARNESS_SCRIPT"), os.environ.get("FAKE_HARNESS_RC", "0"))


def resume(worktree, state_dir, session_id, prompt):
    _log("resume", state_dir, session_id, prompt)
    script = os.environ.get("FAKE_HARNESS_RESUME_SCRIPT") or os.environ.get("FAKE_HARNESS_SCRIPT")
    rc = os.environ.get("FAKE_HARNESS_RESUME_RC", os.environ.get("FAKE_HARNESS_RC", "0"))
    return _replay(state_dir, script, rc)


def events(state_dir):
    try:
        with open(os.path.join(state_dir, "events.jsonl")) as f:
            return [json.loads(l) for l in f if l.strip()]
    except OSError:
        return []
