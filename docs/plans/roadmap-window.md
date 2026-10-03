# Plan: the Chief Stew window and the roadmap

Status: **proposed, revised after review**, not started. The contract changes are in `event-contract.md` § 4c and `workflow.md` § Roadmap.

## Why

The panel is a notification surface: what's broken, what needs you, what's moving. Two things don't fit in it:

1. **The plan.** Status covers builds in flight, by design (§ 4b: "leave out merged or finished builds"). Repos that write down their plan hold the rest of it: what's done, what's marked next, what's still to come. Chief Stew can't see any of that.
2. **Detail.** The sweep's leftovers (monospace lists, one row per database, process or route) are the panel's bulkiest section. Each addition makes the panel longer.

The question the roadmap must answer is **"what can I pick up next?"** It is not "how far along is the plan?". A repo's own roadmap file and any stakeholder views already answer that one.

## Decisions

| | Decision | Why |
|---|---|---|
| D1 | The panel stays the notification view. The roadmap and anything deeper go in a new window. | A menu-bar extra should be glanceable. The panel is already 452 pt wide with five sections. |
| D2 | **Left behind:** the panel keeps one summary line and the Copy cleanup buttons; the per-item detail moves to the window. The line is hidden when the sweep finds nothing. | Leftovers cost real resources, so they stay visible. Cleanup stays one click from the panel; only the bulky detail moves. |
| D3 | The roadmap is described as data in `.chiefstew.json` (`roadmap`). It's read from git, on the branch status already judges "merged" against. | Same model as `workflow`: nothing runs, and `check` explains it. Using the same branch as merge detection means a build merged on origin can't look unfinished on the roadmap. |
| D4 | No computed dependencies in v1. What the file itself says ("Next", "waits for 012") is read and shown as written. | "Ready" and "blocked" are only facts when the file states them. A `next` status rule and the status text as written cover the real need without Chief Stew interpreting prose. Room is left for an optional `depends` later, as an additive change. |
| D5 | The sidebar lists repos plus **All repos**. All repos shows what can be compared across repos: Now, Up next and Left behind. | Groups and numbering only make sense inside one repo. Up next and leftovers across repos answer "where should I go next?", which the panel can't. |
| D6 | No derived group labels, no predicted dates, no reordering. Groups show their own heading and counts. | "Show facts, not guesses." A derived "complete" or "under way" contradicts files that say what they mean ("complete", "slot-in-anytime"). |
| D7 | No Dock icon. The window comes forward the way Settings does (`WindowFront.raise`). | Switching to a Dock icon gives the app a ⌘Q that quits the whole menu-bar app. It can also send Settings behind other apps, and it would make two inconsistent window models. |

## What the owner sees

Copy follows the panel's rules: plain words, and no em dashes (headings are trimmed with the named group `name`).

### Panel (changed)

- **Unchanged:** Problem, Needs you, In progress, Teammates.
- **Left behind** has two parts:
  - one summary line: `Left behind · 2 databases, 1 process` with **Details**, which opens the window. With one repo affected it opens that repo's Left behind tab; with several, it opens All repos.
  - the existing **To clean up** Copy buttons, unchanged and still one click.
  - The per-item rows (names, PIDs, hostnames) move to the window.
- **Footer:** a new icon, *Open Chief Stew* (`macwindow`, ⌘O), between Refresh and Repos.

### Window (new)

```
┌──────────────┬──────────────────────────────────────────────────────┐
│ All repos    │  my-app                       Roadmap   Left behind  │
│ ──────────── │ ─────────────────────────────────────────────────────│
│ my-app     2 │  Now                                                 │
│ other-app    │   012 checkout_flow    ●●◐○○   Plan waiting 12 min   │
│              │   015 order_emails     In progress in the plan,      │
│              │                        not in status                 │
│              │  Up next                                             │
│              │   013 saved_cards      Next (waits for 012)          │
│              │  Stage 2 · Checkout                 1 done, 2 to do  │
│              │   016 address_book     planned                       │
│              │  Stage 3 · Accounts                 0 done, 6 to do ▸│
│              │  Shipped                                          ▸  │
│              │                    Show folded and dropped · Open file│
│              │                          as of last fetch 2 h ago    │
└──────────────┴──────────────────────────────────────────────────────┘
```

- **Sidebar:** All repos, then each registered repo with its count of builds in flight.
- **All repos:** one page with three sections:
  - **Now:** every live build, by repo.
  - **Up next:** each repo's `next` rows, by repo.
  - **Left behind:** every repo's leftovers, with Copy buttons.
- **Per repo, two tabs:**
  - **Roadmap**, top to bottom:
    - **Now:** live builds from status, with parked and teammates' builds labelled as in the panel. Disagreements sit here too ("In progress in the plan, not in status").
    - **Up next:** rows the file marks next, with their status text.
    - **Groups:** in file order, each with its heading and counts. A group with nothing to do is collapsed.
    - **Shipped:** groups where every row is done or folded, newest first, collapsed.
    - **Bottom bar:** "Show folded and dropped", **Open file** (the roadmap file, read-only from git as for artefacts), and "as of last fetch …" when the file came from origin.
  - **Left behind:** today's panel section, in full.
- **Problems and empty states:**
  - **No `roadmap` block:** one line explaining it, with **Copy roadmap setup prompt**.
  - **A roadmap problem** (the file is missing, too big or has a bad regex): the problem and its hint, with Copy. Status is unaffected.
- **Behaviour:**
  - There's one window, which remembers its size and selection. ⌘W closes it.
  - Updates wait while it's open, as they do for the panel.

## Engineering

### Core (`ChiefStewCore`)

- **`RoadmapSpec`:** parses `roadmap` like `WorkflowSpec`. It reports unknown keys, compiles the regexes and applies the same path rules (relative, no `..`).
- **`RepoConfig`:** reads `roadmap` alongside `workflow` or `status`, or on its own. It gains `roadmap: RoadmapSpec?` and `roadmapProblem: String?`, so a broken roadmap is reported without failing the whole `load` result. A roadmap-only config is valid: agents-only status, plus the roadmap. `check` warns about unknown top-level keys.
- **Source branch:** `RoadmapReader.ref()` is the branch merge detection uses (see the contract). It's origin's default branch when that contains the local default branch, else the local default branch. It never falls back to `HEAD`: no default branch is a reported problem.
- **`RoadmapReader`:**
  - Check the blob size first (`cat-file -s`), so a file over 256 KB is a stated problem, not a silent nil.
  - Read the file (`show`) and skip fenced blocks.
  - Build a heading tree. Each table is assigned to its closest ancestor heading that matches `group.match`.
  - Map columns by header name. Parse table rows, handling `\|`, `|` inside backticks, missing outer pipes and alignment rows.
  - Strip markdown from every cell (`WorkflowEngine.plain`).
  - Classify status in the order dropped, folded, done, active, next, planned.
  - Treat rows whose `num` doesn't look like an ID as unnumbered.
  - Dedupe numbered rows (first wins, duplicates recorded).
- **`Roadmap`:** `groups: [Group { heading, name, rows: [Row { num?, name, status, text, date? }] }]`, plus `ref`, `fetchedAt?`, `duplicates` and `notes`.
- **`Roadmap.join(status:)`:** pure. Rows match status rows exactly by `num`, one-to-many. It produces Now (live, plus the in-progress disagreements), Up next, the groups with their counts, and Shipped.
- **When it's read:** keyed on the file's blob ID (`rev-parse <ref>:<file>`), checked with each status poll. It's re-parsed only when that changes, i.e. on a commit to the default branch or a fetch.
- **`RepoSnapshot`:** gains `roadmap: Roadmap?` and `roadmapError: RepoError?`.

### UI (`ChiefStewUI`)

- **`PanelView`:** the Left behind summary line plus its Copy buttons, and the footer icon.
- **Window content:** `RoadmapView`, `LeftBehindView` and `AllReposView`. Each is a plain stack, a pure function of `Board` plus `[repo: Roadmap]` and `PanelActions` (new: `openWindow(repo?, tab)`). Each is rendered on its own in snapshot tests, because `ImageRenderer` can't render split views, tab views or scrolling.
- **Window chrome:** `NavigationSplitView` with a sidebar and a tab picker. It's kept thin and isn't snapshot-tested.
- **Snapshot states:**
  - no roadmap, and a roadmap problem
  - every row status, including unnumbered rows, a duplicate and a disagreement
  - an empty Up next, a collapsed Shipped, and "as of last fetch"
  - All repos with one repo, and with several
  - the new panel Left behind

### App (`ChiefStew`)

- **Scene:** `Window("Chief Stew", id: "board")`, opened with `openWindow` through `PanelActions` and brought forward with `WindowFront.raise`. The selection (repo and tab) lives in `AppModel`, so the panel can open the window on a given place.
- **Window open:** `AppModel.windowOpen`, set by a `WindowAccessor` observer. `installIfAutomatic` waits on `panelOpen || windowOpen`.
- **Updates:** on a relaunch for an update, the window is reopened if it was open, the same way Settings is.
- **Restoration:** state restoration is off for this scene (`.defaultLaunchBehavior(.suppressed)` / `restorationBehavior(.disabled)` where available on macOS 14, else closed in `applicationDidFinishLaunching`). That way the window never reappears by itself at login.

### CLI

- **`chiefstew roadmap`** prints the parsed roadmap as JSON. It's for diagnosis only, not part of the contract.
- **`chiefstew check`** gets a Roadmap section:
  - the source branch, its freshness and the file size
  - per group, the rows read and the tables skipped (with the reason)
  - status text that matched no rule
  - unnumbered rows and duplicates
  - unknown keys
- **`chiefstew prompt roadmap`** is a roadmap-only setup prompt for repos that already have `workflow` or `status`. Its job ends when `check` reports a roadmap with nothing unexplained. Settings → Repos and the window's empty state copy it.

### Docs

- `event-contract.md` § 4c and `workflow.md` § Roadmap (written).
- `architecture.md`: the window in the module table, and D1, D6 and D7 under "Decisions that hold".
- `docs/mockup/states.html`: the new panel Left behind and the window states.

## Phases

1. **Prove the parser; no UI yet.** `RoadmapSpec`, `RoadmapReader`, the join, `chiefstew roadmap`, `check` and `prompt roadmap`, with unit tests and an invented demo roadmap in `dev/demo-repo`. **Go/no-go:** run `check` on a real repo's roadmap. Every row should be read or explained, the group tables should be read and the summary tables skipped, and the status text that matches no rule should be text the owner agrees is "planned". If the description can't express the real file, fix the format before building any UI.
2. **The window and the panel change, together.** The window scene, the sidebar, Roadmap, Left behind, All repos, the panel's Left behind line, the footer icon, update gating and snapshots.
3. **Later, only if real use asks:**
   - a Builds detail tab (every phase with its times, and gate history)
   - an optional `depends`, giving ready and blocked labels
   - a `start` command template to copy, like `approve`
   - an Activity tab built from `events.jsonl`

## How we'll know it works

There's no telemetry, so the test is plain and judged by the owner two weeks after phase 2:

- Whoever picks the next build does it from the window (Up next, Now), without opening the roadmap file.
- `chiefstew check` on the real repo still explains every row as the file changes.
- Leftovers are still cleaned up from the panel at least as often as before.

If the first isn't true, revisit the Roadmap view before adding anything else to the window.

## Testing

- **`swift test`:**
  - the parser: heading-tree grouping, every table edge case, fences, markdown in cells, unnumbered rows, duplicates, the size limit and the source-branch choice
  - the join: one-to-many, parked builds, teammates, origin-only branches, and disagreements
  - the snapshot states above
- **Demo:** `dev/demo.sh roadmap` with the invented demo repo.
- **Phase 1's go/no-go** on a real repo.

## Risks

| Risk | Mitigation |
|---|---|
| A plan written as prose, not tables | Out of scope. `check` explains what was skipped. |
| A roadmap file growing past 256 KB | `check` states the size against the limit, and the problem says how to fix it: split the file, or use `section`. |
| The file and status disagree | Status wins for anything live. "In progress in the plan, not in status" is shown, not hidden. |
| The roadmap from origin is as old as the last fetch | Chief Stew never fetches. It says "as of last fetch …", as it already does for origin-only builds. |
| The window and panel drifting apart | Both render the same `Board`; there's no second source of truth. |
