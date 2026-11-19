# M03 — held-reread

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D06, M02 | none | S |

**Owns:** in `scheduler/site.py` and `scheduler/api.py`, the `/proc/locks` read of `held()` (the re-read before the
fdinfo fallback) and the docstring of each `held()`; the M03 cases added at the end of `scheduler/loops-pidns.test.sh`
(after M02's), with their scenario and the FIFO writers they start.
**Resolves:** #186

## Purpose
After this node the status page (`site.py`) and the API (`api.py`) no longer report a running loop or API server as
stopped because of one bad read of `/proc/locks`. `/proc/locks` is a seq_file read by position: when other locks come
and go during one read, a line can be skipped, even within one read, once the list is larger than a page (about 4 KB).
A skipped line is a false "not held". M02 fixed this in `held()` of `scheduler/loops.sh`, which reads the list afresh
(a new open), up to three reads in all, before it says "not held". The probes `held()` of `site.py` and `api.py` (D06's
change 8) still read the list once. This node gives them the same re-read. The rest of each probe stays as D06 left
it: the lock is never taken, the device fallbacks are the same, and the fdinfo fallback still runs only after the
reads find no line, where `scan_fdinfo()` allows it.

## Tests
- `scheduler/loops-pidns.test.sh` (cases added at its end, no existing line changed): a scenario of its own with a lock
  file that no process locks (a control check takes the lock with `flock -n`, so the fdinfo fallback cannot find a
  holder and only a re-read can), and `NOODLEBOT_PROC_LOCKS` pointing at a FIFO. A writer serves the FIFO one list
  per open, as M02's `M02-AC-2:held-rereads:*` cases do: the list with the file's line is made by the file's
  `fab.py`, the list without it by changing the line's inode. Each probe gets a writer of its own, started before the
  probe and stopped after it by its recorded pid, and each probe runs under `timeout`, so a probe that reads more often
  than the writer serves fails its case instead of hanging the file.
  - re-read finds the line: the writer serves the list without the line first and the list with it next; `site.py`'s
    and `api.py`'s `held()` each report the lock held. On `main` before this node each reports it free (the RED).
  - three reads, then not held: the writer serves only lists without the line and counts the lists it has served; each
    probe reports the lock free, and the count is 3 once the probe has returned (the case waits for the count, with a
    bound, instead of a fixed sleep). On `main` before this node the count is 1 (the RED).
  - the existing D06-AC-11 and M02-AC-2 cases of the file keep passing unchanged.

## Changes
1. **`held()` in `scheduler/site.py`.** When the read of `/proc/locks` (or of the file `NOODLEBOT_PROC_LOCKS` names)
   has no line for the lock file, the list is opened and read again, up to three reads in all, before `scan_fdinfo()`
   and the fdinfo fallback; a read that matches returns at once, so a held lock found on the first read costs one
   read, as now. A failed open is treated as it is now. The docstring says the list is re-read and why, as the comment
   in `loops.sh`'s `held()` does. *M03-AC-1, M03-AC-2.*
2. **`held()` in `scheduler/api.py`.** The same change, through its `read_text()`. *M03-AC-1, M03-AC-2.*
3. **The cases** of **Tests**, in `scheduler/loops-pidns.test.sh`, which already exercises both probes (D06-AC-11) and
   holds M02's re-read cases for `loops.sh`. The file keeps under `TEST_FILE_BUDGET` (30 s): each served list costs
   about a second, so the four probes add about ten seconds to a file that runs in about seven. *M03-AC-3.*

## Gate
- **M03-AC-1** — With `NOODLEBOT_PROC_LOCKS` set to a FIFO whose first open gives a list without the lock file's line and whose next open gives a list with it, and no process holding the lock (so the fdinfo fallback finds no holder), `held()` in `scheduler/site.py` and `held()` in `scheduler/api.py` each report the lock held; on `main` before this node each reports it free. *Verify:* `sh scheduler/loops-pidns.test.sh` (the `M03-AC-1:*` cases), and the RED run recorded in the PR.
- **M03-AC-2** — With `NOODLEBOT_PROC_LOCKS` set to a FIFO that gives only lists without the lock file's line, and no process holding the lock, `held()` in `scheduler/site.py` and `held()` in `scheduler/api.py` each report the lock not held after reading the list three times in all, counted by the lists the FIFO's writer served. *Verify:* `sh scheduler/loops-pidns.test.sh` (the `M03-AC-2:*` cases).
- **M03-AC-3** — The node changes no existing line of the frozen paths (`*.test.sh`, `scheduler/testdata/`): it adds cases at the end of `scheduler/loops-pidns.test.sh` only, the file's existing D06-AC-11 and M02-AC-2 cases pass, and its `TIME` line in the PR's CI run is under `TEST_FILE_BUDGET`. *Verify:* the `git diff origin/main -- '*.test.sh' scheduler/testdata/` recorded in the PR and the PR's CI run.

## Risks
- A probe that finds no line now reads the list three times. `site.py` probes every listed repository's locks on each
  tick and `api.py` on each request; the list is a few kilobytes, so the cost stays small next to the fdinfo fallback
  that may follow it.
- Three reads make a false "not held" much less likely, not impossible: under heavy lock churn all three can skip the
  line, as in `loops.sh`.
- The FIFO cases depend on the writer serving one list per open; a writer that opens again while a reader is still on
  the last list joins two lists in one read. M02's writer waits a second between lists for this; the new writers do
  the same.
- By AGENTS.md's quick-gate rule, a change to `site.py` or `api.py` runs `site*.test.sh` or `api*.test.sh`, not
  `loops-pidns.test.sh`; this node names `loops-pidns.test.sh` as its red target, and CI runs it on every PR.
