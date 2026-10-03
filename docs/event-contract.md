# Chief Stew contract (v1)

How a repo tells Chief Stew what's in flight and what needs its owner. Any repo can take part. Nothing here depends on a particular language, build tool or agent. Chief Stew's Add Repo wizard embeds this file, and [workflow.md](workflow.md), in the setup prompt it generates.

Chief Stew learns about a repo in two ways:

| | What | Role | Who does the work |
|---|---|---|---|
| **Status** | A read-only command in the repo that prints JSON (§4), plus an optional sweep (§5) | **Truth**: what the panel shows | Chief Stew runs it about once a minute |
| **Events** | One small JSON file per event, dropped in an inbox folder (§2–3) | **Hints**: fast, and may be lost or duplicated | Claude Code hooks (installed by Chief Stew) and, optionally, the repo's own scripts |

Events mostly just make Chief Stew re-read status sooner, so a lost or duplicated event is corrected by the next poll. The one exception is agent state (§3.3), which comes from events alone.

Everything is local: files and child processes. There are no sockets, no listeners, no network calls and no telemetry. Chief Stew never changes a repo.

A repo can do any subset:

| Repo provides | Owner sees |
|---|---|
| Nothing | Its agents: which session is asking a question or needs permission (from Chief Stew's own Claude Code hooks), and which is working or idle (from Claude Code's own session list). |
| A status command | Its builds as well: phases, gates waiting for sign-off, tasks, parked and unmerged work |
| A sweep command | Leftovers too: leaked databases, stray processes and routes |
| Events from its scripts | Gates and phase changes appear at once, not at the next poll |
| A roadmap description | The plan around its builds: what's shipped, what's marked next and what's still to come (§4c) |

## 1. Locations

| Path | Owner | Meaning |
|---|---|---|
| `~/Library/Application Support/Chief Stew/` | Chief Stew | The home folder. `$CHIEFSTEW_HOME` overrides it (for tests and dev runs); emitters must honour the same variable. |
| `…/inbox/` | Chief Stew creates it on first launch | If it **exists**, Chief Stew is **installed**. Emitters never create it. |
| `…/alive` | Chief Stew touches it every 60 s while running **and allowed to post notifications**. It deletes the file on quit, or when permission is off. | If its mtime is **under 180 s old**, Chief Stew is **running** and will notify. |
| `…/waiting/<session>` | `chiefstew hook` writes it when a session asks for input and removes it on the session's next sign of life; Chief Stew keeps it in step for other emitters. One empty file per agent session that needs input | Lets a hook that runs on every tool call skip all work unless something is waiting (`agent.active`, §3.2). The name is the session ID reduced to `[A-Za-z0-9_-]`, at most 128 characters (`session` if nothing is left). |
| `…/events.jsonl`, `…/events.1.jsonl` | Chief Stew | The journal: every event handled, one §3.1 JSON object per line. Replayed at launch to rebuild agent state; read it when state looks wrong. Rotated at 4 MB. |
| `/Applications/Chief Stew.app/Contents/Helpers/chiefstew` | Chief Stew | The bundled command: `chiefstew hook …` for Claude Code hooks and `chiefstew emit …` for repo scripts (§2.1). |

## 2. Emitter rules

1. **Skip silently** if the inbox folder doesn't exist.
2. **Write atomically:** write `inbox/.<name>.tmp`, then `rename` it to `inbox/<name>`. The name is `<unix-ms>-<pid>-<4 random hex>.json`, e.g. `1790776931123-48211-9f3a.json`. Chief Stew ignores dotfiles and anything not ending in `.json`, and reads only regular files.
3. **Never fail the caller.** Emitting is best effort. Every error is swallowed; at most one line goes to stderr.
4. **Keep files small:** one JSON object, UTF-8, under 16 KB. `message` is at most 200 characters.
5. **Notifications:** an emitter that also shows its own desktop notification **skips it while Chief Stew is running** (fresh `alive`), so the owner gets one notification, not two. If Chief Stew is installed but not running, the emitter notifies as it always did, so nothing is lost.

### 2.1 The easy way: `chiefstew emit`

A repo's scripts don't need their own emitter. The bundled command follows all the rules above:

```sh
CS="/Applications/Chief Stew.app/Contents/Helpers/chiefstew"
[ -x "$CS" ] && "$CS" emit gate.waiting --build 012 --gate review --slug my_feature
```

Flags: `--build`, `--gate`, `--phase`, `--slug`, `--lane`, `--message`, `--session`, `--agent`, and `--repo <folder>` (default: the git checkout of the current folder). An invalid event is reported on stderr and not written. It always exits 0. Keep the `[ -x ]` guard so the script still works for anyone without Chief Stew.

## 3. Events

### 3.1 Shape

```json
{
  "v": 1,
  "id": "3f6c1e0a-…",
  "ts": "2026-09-30T14:02:11.123Z",
  "kind": "gate.waiting",
  "repo": "/Users/you/my-app",
  "worktree": "/Users/you/my-app/.claude/worktrees/feature-x",
  "build": "012",
  "slug": "feature_x",
  "phase": 3,
  "gate": "review",
  "session": "5c1e…",
  "agent": "claude-code",
  "message": "optional human text"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `v` | int | yes | `1`. Any other value is skipped and logged. |
| `id` | string | no (recommended) | Unique per event, e.g. a UUID; at most 64 characters. A copy with an `id` already handled is ignored. `chiefstew emit` and `chiefstew hook` set one. |
| `producer` | string | no | Who sent it: `chiefstew-hook`, `chiefstew-emit`, or the sender's own name. Chief Stew uses it to spot a repo re-sending the agent events its hooks already send, and says so in Settings and `chiefstew check`. |
| `ts` | string | yes | ISO 8601 with a zone. If it can't be parsed, the file's mtime is used instead. |
| `kind` | string | yes | See §3.2. Unknown kinds are ignored, so the contract can grow. |
| `repo` | string | yes | Absolute path of the repo's **main** working tree (the parent of `git rev-parse --path-format=absolute --git-common-dir`). Must match a repo registered in Chief Stew. |
| `worktree` | string | no | Absolute path of the checkout the event came from (its git top level), if it differs from `repo`. It must lie inside `repo`, or it's ignored. |
| `build` | string | per kind | The build's ID as the status command reports it (`num`, §4), e.g. `"012"`. |
| `slug` | string | no | e.g. `feature_x`. |
| `lane` | string | no | A repo-defined route name, e.g. `full` or `fast`. |
| `phase` | int | per kind | 1-based. |
| `gate` | string | per kind | The repo's own gate name: lowercase `[a-z0-9_-]`, 1–32 characters. |
| `session` | string | per kind | The agent's session ID (Claude Code's `session_id`). |
| `agent` | string | no | `claude-code`, `codex`, … Shown as "Claude", "Codex", or the name capitalised. |
| `notification_type` | string | no | Passed through from Claude Code's Notification hook when present (`permission_prompt`, `elicitation_dialog`, `idle_prompt`, …). Chief Stew uses it to tell a question from a reminder (§3.3). |
| `host_app`, `host_pid`, `tty` | string, int, string | no | The app running the agent's session (e.g. `com.mitchellh.ghostty`), its process ID and the terminal device. `chiefstew hook` records them by walking up from the hook's process; **Go to session** uses them to bring that app forward. |
| `message` | string | no | At most 200 characters. |

Unknown fields are ignored.

### 3.2 Kinds

| Kind | Required beyond the base | Typically sent by | Effect in Chief Stew |
|---|---|---|---|
| `phase.started` | `build`, `phase` | The repo's scripts | Refresh status |
| `phase.done` | `build`, `phase` | The repo's scripts | Refresh status |
| `gate.waiting` | `build`, `gate` | The repo's scripts | Refresh status. For a repo whose status can't show the gate (not registered, not read yet, or failing), the gate is shown and notified from events until `gate.approved` or `build.closed`. |
| `gate.approved` | `build`, `gate` | The repo's scripts | Refresh; stops reminders for that gate |
| `build.closed` | `build` | The repo's scripts | Refresh |
| `agent.needs_input` | `session` | Claude Code **Notification** hook | **Needs you** (§3.3) and notify, unless it's an idle reminder or an auth notice |
| `agent.stopped` | `session` | Claude Code **Stop** hook | Records last activity; refresh; clears needs-input |
| `agent.resumed` | `session` | Claude Code **UserPromptSubmit** hook | Clears needs-input |
| `agent.active` | `session` | Claude Code **PostToolUse** hook, **only while `waiting/<session>` exists** (the hook then removes it) | Clears needs-input: a tool ran, so a permission prompt was answered |
| `agent.ended` | `session` | Claude Code **SessionEnd** hook | Forgets the session, so a closed tab no longer "needs you" |

A session's `repo` is the project it was started in (Claude Code's `CLAUDE_PROJECT_DIR`), not wherever it last changed directory to.

Chief Stew installs the five Claude Code hooks itself, into `~/.claude/settings.json`, so they cover every repo. A repo doesn't need to add them. Each hook runs `chiefstew hook notify|stop|prompt|active|end`, prints nothing, always exits 0, and does nothing if Chief Stew is gone. **One producer per fact:** a repo shouldn't send agent events from its own hooks. (If it does, a second copy of the same kind from the same session within 3 s is ignored, but that's a safety net, not a design.) Events state facts; deciding what to show and notify is Chief Stew's alone, so emitters never post notifications while Chief Stew is running (§1, `alive`).

### 3.3 Agent state (the one thing events own)

Status knows nothing about agent sessions, so Chief Stew keeps a small per-`session` record built from events alone:

- `agent.needs_input` sets **needs input**, with its `message`.
- Any later event from the same session (by `ts`), other than another `agent.needs_input`, clears it.
- Not every Notification is a question. With `notification_type` `idle_prompt` (Claude Code's reminder 60 s after a turn ends) or `auth_success`, or with no type and the message `Claude is waiting for your input`, the event changes nothing: the Stop before it already showed the session as idle.
- `agent.ended` removes the session.
- A needs-input record older than 8 h expires, and a session with no events for 24 h is forgotten.
- Agent state is saved to `…/agents.json`, so it survives a relaunch or an update.
- A session belongs to a build when its `worktree` (or `repo`) **equals** that build's checkout (a status row's `worktree`). Rows that share a build ID count as one build with several checkouts. Otherwise the session shows as "Claude in `<folder name>`".

### 3.4 Chief Stew's reading rules

- It reads the inbox on start and on every change to the folder, sorted by `ts` then filename. It deletes each file once handled.
- A malformed file (bad JSON, over 16 KB, missing required fields, wrong `v`, not a regular file) is logged with its first 200 bytes through `os_log` and deleted. It never causes a crash.
- Events older than 24 h at read time are dropped.
- Duplicates are harmless: a copy with an `id` already handled is ignored.
- Every event handled is appended to the journal (§1). At launch, Chief Stew replays the last 24 h of it to rebuild agent state and event-only gates.

## 4. Status

### 4a. Where status comes from: `.chiefstew.json`

`.chiefstew.json` at the repo root, committed with the repo and read as JSON5, gives Chief Stew status in one of two ways.

**A `workflow` description (preferred).** The repo describes where it writes things down: which branches, worktrees or folders are builds, and which files and sections hold their state, phases, gates and tasks. Chief Stew's built-in engine produces the status below. It's data: no code from the repo runs. The format is in [workflow.md](workflow.md); `chiefstew check` explains what the engine found, and `chiefstew status` prints the result.

```json5
{ "v": 1, "workflow": { "builds": { "from": "branches", "branch": "feature/{slug}" }, "state": { "file": "STATUS.md" } } }
```

**A `status` command (the escape hatch),** for a process a description can't express:

```json
{
  "v": 1,
  "name": "My app",
  "status": ["node", "scripts/status.ts", "--json"],
  "sweep": ["./bin/sweep", "--json"]
}
```

- Each command is an **argv list**, run directly with no shell, with the repo as the working directory.
- argv[0] `node` means the owner's Node, found through their login shell. A program containing `/` is taken relative to the repo. Anything else is looked up on the owner's login `PATH`.
- `sweep` and `name` are optional.
- Use `workflow` or `status`, not both.
- `roadmap` (optional) can sit alongside either, or neither (§4c).
- No `.chiefstew.json`: the repo is watched for **agents only**.

**Commands must be read-only.** No network (no `git fetch`), no writes, no locks. Chief Stew sets `GIT_OPTIONAL_LOCKS=0` and `NO_COLOR=1`, and kills a status call after 20 s and a sweep after 60 s.

### 4b. Output

The status command prints one JSON object to stdout and nothing else:

```json
{
  "v": 1,
  "generatedAt": "2026-09-30T14:02:12.456Z",
  "repo": "/Users/you/my-app",
  "builds": [
    {
      "num": "012",
      "slug": "feature_x",
      "branch": "feature/x",
      "worktree": "/Users/you/my-app/.claude/worktrees/feature-x",
      "merged": false,
      "lastCommitAt": "2026-09-30T13:40:02Z",
      "behind": 4,
      "flags": [],
      "state": "Plan ready — waiting on review",
      "lane": "full",
      "parked": false,
      "phases": [
        { "n": 1, "name": "Draft",  "status": "done",    "startedAt": "2026-09-30T09:12:00+01:00", "doneAt": "2026-09-30" },
        { "n": 2, "name": "Design", "status": "pending", "skipped": true },
        { "n": 3, "name": "Build",  "status": "active",  "startedAt": "2026-09-30T12:01:00+01:00" }
      ],
      "gates": [
        { "gate": "review", "status": "waiting", "at": "2026-09-30T13:50:00Z", "phase": 3,
          "artefact": "/Users/you/my-app/.claude/worktrees/feature-x/docs/plan.md",
          "approve": "make approve BUILD=012" }
      ],
      "tasks": { "done": 6, "total": 11 },
      "urls": { "app": "http://feature-x.my-app.localhost:1355" },
      "progress": "/Users/you/my-app/.claude/worktrees/feature-x/docs/progress.md"
    }
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `v`, `builds` | yes | `builds` holds in-flight work only. Leave out merged or finished builds. |
| `num`, `slug`, `branch`, `state`, `lastCommitAt`, `merged` | yes | `num` is a short ID shown first ("012"). `state` is one plain-text line. `lastCommitAt` is ISO 8601, or unix seconds. |
| `generatedAt`, `repo` | no | |
| `fetchedAt` | no | When the clone last fetched from origin. Rows marked `onlyOnOrigin` are as fresh as this, since Chief Stew never fetches. |
| `worktree` | no | The checkout's path, or `null` if the branch isn't checked out. It's what agent sessions are matched against. |
| `worktrees` | no | Other checkouts working on this build (e.g. an agent's worktree on its own branch); agent sessions there count for it too. |
| `behind` | no | Commits behind the main branch, from local refs. |
| `flags` | no | `closed-unmerged` (finished but not merged: **needs you**, or, for a teammate's build, shown under Teammates with one quiet notice), `idle`, `behind`. |
| `lane` | no | A repo-defined route. |
| `parked` | no | `true`: set aside on purpose. It's dimmed, never in the menu bar, and its gates and merges don't need you. If absent, a `state` starting with "Parked" counts. |
| `phases` | no | In order. `status` is `done`, `active` or `pending`. `skipped: true` hides a phase that isn't on this build's route. Times can be ISO, `YYYY-MM-DD` or local `YYYY-MM-DD HH:MM`. |
| `gates` | no | `status` is `waiting` or `approved`. `at` is when it started waiting (shown as "waiting 12 min"). `phase` is the phase the gate signs off, and its dot turns orange. `artefact` is the file to review; it opens in its default app, and anything executable is only revealed in Finder. `artefactRef` (`ref:path`) names it in git when it isn't on disk; Chief Stew opens a read-only copy. `approve` is the command that signs it off; it's copied, never run. |
| `tasks` | no | `done` / `total`. |
| `urls` | no | Name → URL; the first is offered as "Open app". |
| `progress` | no | A file to open for detail. |
| `author` | no | Who wrote the build's newest commit of its own. |
| `mine` | no | `true` if this clone's git user (`user.email`) wrote any of the build's commits, `false` if not. Absent when that can't be told; the build then counts as yours. |
| `onlyOnOrigin` | no | `true`: the branch exists only on origin, so there's nothing checked out here. |
| `branchURL` | no | The branch's web page, offered as "Open on GitHub" when there's no checkout. |
| `budget` | no | `{ "hours": 2, "label": "L" }`: how long the build is meant to take, wall clock from its first phase's start. Shown as elapsed against it (`L · 1h 10m of 2h`, then `over by 35 min`), except for a parked or closed build. Once one of yours is over, it gets one quiet notice. `label` is optional. |

Anything optional can be left out: a row with only the required fields still shows. A row that fails to decode is skipped and counted, and never takes down the rest.

### 4c. Roadmap (optional)

Status covers builds in flight only. A repo that writes its plan down (a markdown file listing builds that are done, under way and still to come) can point Chief Stew at it with a top-level `roadmap` description in `.chiefstew.json`:

```json5
{
  "v": 1,
  "workflow": { /* … */ },
  "roadmap": {
    "file": "docs/roadmap.md",
    "group": { "match": "^(?<name>Stage \\d+|Anytime pool)" },
    "columns": { "num": "#", "name": "Build", "status": "Status" },
    "status": {
      "done": "^Done(?: (?<date>[\\d-]+))?",
      "folded": "^Merged into",
      "dropped": "^Dropped",
      "active": "^In progress",
      "next": "^(Next|Ready)",
    },
  },
}
```

- It's data, like `workflow`: nothing runs. The format is in [workflow.md](workflow.md#roadmap-the-plan-around-the-builds), and `chiefstew check` explains what was read, row by row.
- **Which version of the file:** the one on the branch status judges "merged" against. That's origin's default branch as last fetched when it contains the local one, else the local default branch (origin's default branch name, else `main`, else `master`). It's never whatever is checked out, so uncommitted edits and build branches don't change it. When it comes from origin, it's as fresh as the last fetch, and Chief Stew says so. If there's no default branch, the roadmap reports a problem.
- **Joining to status:** rows are joined to status by `num`, compared exactly as status reports it. One row matches every status row with that `num` (one build, several checkouts, §3.3). A build that status reports is shown live from status, whatever the file says about it. The file supplies only what status can't: builds not started, builds finished, what's marked next, and how it's grouped.
- **Errors stay separate:** a broken or unreadable roadmap is reported on its own and never stops status.
- **A status command can't supply a roadmap** in v1. A repo using `status` describes its roadmap with this block like any other, and Chief Stew reads the file with git itself.
- **`chiefstew roadmap` is for diagnosis only:** it prints what Chief Stew read as JSON. That output isn't part of the contract and may change.

## 5. Sweep (optional)

The sweep command reports leftovers from finished work. It only reports; it never deletes anything.

```json
{
  "v": 1,
  "databases": { "checked": true, "leaked": ["myapp_wt_fix_b"] },
  "routes": [ { "hostname": "fix-b.my-app.localhost", "reason": "process 5512 is gone" } ],
  "processes": [ { "pid": 67816, "cwd": "/Users/you/my-app/.claude/worktrees/129" } ],
  "cleanup": ["make clean-worktree-dbs", "portless prune"],
  "errors": []
}
```

- Every field is optional. If a check couldn't run (e.g. Docker is down), say so in `errors` and still exit 0.
- `cleanup` lists commands the owner can run. Chief Stew shows and copies them but never runs them.
- Chief Stew runs the sweep once status first succeeds, then every 15 minutes and on Refresh.

## 6. How Chief Stew runs commands

- **PATH:** read once from the owner's login shell (`$SHELL -l`), because a GUI app doesn't inherit one. The same lookup finds `node`, and Settings can override the path. Node is only needed by commands that start with `node`.
- **Schedule:** status runs every 60 s, 2 s after an event for the repo, when the panel opens (if the last result is over 10 s old), and on wake from sleep. Keep it fast.
- **Failure:** a non-zero exit, a timeout or bad JSON keeps the last good result and marks the repo **stale**, showing the error and a hint. A missing or moved repo shows as an error, never a hang.

## 7. Versioning

Adding optional fields or new kinds is **not** a version change. That covers `.chiefstew.json` too: from v0.2.2, keys inside `workflow` and `roadmap` that a copy doesn't know are ignored (and reported by `chiefstew check`), so a description written for a newer Chief Stew still works on an older one, without the newer key's effect. Copies before v0.2.2 rejected such keys, so a repo committing a key added since should expect teammates to have updated. Removing or renaming a field, or changing what one means, bumps `v`. Chief Stew then supports both versions for one release.
