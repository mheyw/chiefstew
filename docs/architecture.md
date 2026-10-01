# How Chief Stew works

Chief Stew is a macOS 14+ menu-bar app, written only in Swift and built with SwiftPM (no Xcode project). It **displays** what's in flight in the repos you register, and what needs you. It never runs builds or changes a repo. Everything is local: no network listeners, no telemetry.

```
 your repo                         Chief Stew.app                          you
 ─────────                         ──────────────                          ───
 status (engine or command) ──(~60 s)─▶ StatusClient ─┐
 sweep command  ──(15 min)───────▶                ├─▶ Board.make ─▶ menu bar + panel
 scripts ─ chiefstew emit ─┐                      │        │
 Claude Code hooks ────────┴─▶ inbox/ ─▶ InboxReader ─▶ AgentTracker
                                                           └─▶ NotificationPlanner ─▶ notifications
```

- **Status is the truth; events are hints.** A missed event is corrected at the next poll. The exception is agent state (who's asking a question), which only events carry. That's kept in `agents.json`.
- **The contract** is [event-contract.md](event-contract.md). A repo takes part with an optional `.chiefstew.json` naming its status and sweep commands, events from its scripts through the bundled `chiefstew emit`, and nothing else. Claude Code hooks are installed once for all repos, by Chief Stew.
- **Setting up a repo** is the Add Repo wizard. You pick a git repo and install the Claude Code hooks for every repo with one click. Then, optionally, **Run setup prompt** with your coding agent: it describes the repo's workflow in `.chiefstew.json` (data, not code; [workflow.md](workflow.md)) and verifies it with `chiefstew check`, and the wizard shows the result live. Agent-first: you never have to write the file yourself.

## Code

| Module | What's in it |
|---|---|
| `ChiefStewCore` | The contract types (`Event`, `StatusReport`, `SweepReport`), `RepoConfig`, the workflow engine (`WorkflowSpec`, `WorkflowEngine`, `WorkflowCheck`, `WorkflowInit`), `StatusClient`, `CommandRunner` (timeouts; never hangs on inherited pipes), `InboxReader`/`InboxWatcher`, `AgentTracker`, the pure `Board.make` reducer, `NotificationPlanner`, `Emitter`, `ClaudeHooks` (the hook installer), `SetupPrompt`, and `SourceUpdate`. All of it is unit-tested. |
| `ChiefStewUI` | The panel and the menu-bar label, as pure functions of a `Board`, rendered offscreen in tests |
| `ChiefStew` | The app: `AppModel` (polling, inbox, notifications, updates), Settings, the Add Repo wizard |
| `chiefstew-cli` | The bundled `chiefstew` command: `status`, `check`, `init` and `prompt` (setup), `emit` (repo scripts), and `hook` (Claude Code) |

## Decisions that hold

- Swift only, with no daemon. A background service (a supervisor that restarts processes, or a reaper that cleans them up) would only be added if real use shows a need.
- The app never runs cleanup. It shows the commands and copies them.
- There are no Live Activities, because on macOS they need an iPhone app, a server and a paid developer account.
- Updates build from your own clone: when `main` moves, the panel offers **Install update**, which runs `./build.sh update` on a clean export of `main`.

