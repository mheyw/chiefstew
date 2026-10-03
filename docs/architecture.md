# How Chief Stew works

Chief Stew is a macOS 14+ menu-bar app, written only in Swift and built with SwiftPM (no Xcode project). It **displays** what's in flight in the repos you register, and what needs you. It never runs builds or changes a repo. No network listeners and no telemetry. The one network access is checking Chief Stew's own repo for updates.

```
 your repo                         Chief Stew.app                          you
 ─────────                         ──────────────                          ───
 status (engine or command) ──(~60 s)─▶ StatusClient ─┐
 sweep command  ──(15 min)───────▶                ├─▶ Board.make ─▶ menu bar + panel
 scripts ─ chiefstew emit ─┐                      │        │
 Claude Code hooks ────────┴─▶ inbox/ ─▶ InboxReader ─▶ EventState ─▶ events.jsonl
                                                (AgentTracker, EventGates)
                                Board.make ─▶ NotificationPlanner ─▶ notifications
```

- **Status is the truth; events are hints.** A missed event is corrected at the next poll. The exception is agent state (who's asking a question), which only events carry.
- **Events are facts; Chief Stew decides.** Emitters say what happened and never decide what to notify. Each fact has one producer: agent events come only from Chief Stew's own Claude Code hooks, and a repo's scripts send only what only they know (phases, gates, closing). Everything Chief Stew knows from events is `EventState`, a fold over them in order, and the board and its one `NotificationPlanner` are the only place notifications come from. Every event handled is appended to `events.jsonl`, and launch replays it, so state after a relaunch is exactly state before it, and the journal is what to read when state looks wrong. `agents.json` is only a snapshot.
- **The contract** is [event-contract.md](event-contract.md). A repo takes part with an optional `.chiefstew.json` naming its status and sweep commands, events from its scripts through the bundled `chiefstew emit`, and nothing else. Claude Code hooks are installed once for all repos, by Chief Stew.
- **Setting up a repo** is the Add Repo wizard. You pick a git repo and install the Claude Code hooks for every repo with one click. Then, optionally, **Run setup prompt** with your coding agent: it describes the repo's workflow in `.chiefstew.json` (data, not code; [workflow.md](workflow.md)) and verifies it with `chiefstew check`, and the wizard shows the result live. Agent-first: you never have to write the file yourself.

## Code

| Module | What's in it |
|---|---|
| `ChiefStewCore` | The contract types (`Event`, `StatusReport`, `SweepReport`), `RepoConfig`, the workflow engine (`WorkflowSpec`, `WorkflowEngine`, `WorkflowCheck`, `WorkflowInit`), `StatusClient`, `CommandRunner` (timeouts; never hangs on inherited pipes), `InboxReader`/`InboxWatcher`, `EventState` (`AgentTracker`, `EventGates`, `EventJournal`), the pure `Board.make` reducer, `NotificationPlanner`, `Emitter`, `ClaudeHooks` (the hook installer), `SetupPrompt`, and `SourceUpdate`. All of it is unit-tested. |
| `ChiefStewUI` | The panel and the menu-bar label, as pure functions of a `Board`, rendered offscreen in tests |
| `ChiefStew` | The app: `AppModel` (polling, inbox, notifications, updates), Settings, the Add Repo wizard |
| `chiefstew-cli` | The bundled `chiefstew` command: `status`, `check`, `init` and `prompt` (setup), `emit` (repo scripts), and `hook` (Claude Code) |

## Decisions that hold

- Swift only, with no daemon. A background service (a supervisor that restarts processes, or a reaper that cleans them up) would only be added if real use shows a need.
- The app never runs cleanup. It shows the commands and copies them.
- There are no Live Activities, because on macOS they need an iPhone app, a server and a paid developer account.
- **Distribution is source-based.** Each Mac builds its own copy (`./build.sh install`), so there's no Apple Developer account, no notarization and no Gatekeeper warnings. That suits a team of developers. A product for non-developers would switch to Developer ID signing, notarization and a download-based updater.
- **Updates are releases.** `./release.sh X.Y.Z` tags `vX.Y.Z`. Installed copies fetch Chief Stew's own repo hourly (its only network access; watched repos are never fetched), then build and install the newest release tag while you're not using the app. Updates are a progressive enhancement: a copy built from a zip, or without repo access, works fully and just doesn't update.

