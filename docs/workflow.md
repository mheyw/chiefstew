# Describing a repo's workflow

`.chiefstew.json` at the repo root, committed with the repo, can describe **where the repo writes its work down**. Chief Stew reads the description and works out what's in flight: builds, phases, gates waiting for sign-off, and tasks. It's data, not code, and nothing in the repo is run. The file is read as **JSON5**, so comments, trailing commas and unquoted keys are fine.

Check a description at any time:

```sh
chiefstew check    # every build found, and per field what matched or why not
chiefstew status   # the exact JSON Chief Stew will show (contract § 4)
```

`chiefstew` is bundled with the app at `/Applications/Chief Stew.app/Contents/Helpers/chiefstew`. Add `--workflow other.json5` to try a description without writing it into the repo.

## Examples

**Smallest:** each git worktree (other than the main checkout) is a build.

```json5
{ "v": 1, "workflow": { "builds": { "from": "worktrees" } } }
```

**A typical feature flow**

```json5
{
  "v": 1,
  "workflow": {
    // feature/* branches are builds; each keeps its notes in docs/features/<slug>/
    "builds": { "from": "branches", "branch": "feature/{slug}", "folder": "docs/features/{slug}" },
    "state":  { "file": "STATUS.md", "pick": "first-line" },
    "phases": { "file": "PLAN.md", "section": "Phases", "list": "checkboxes" },
    "gates":  { "file": "STATUS.md", "list": "^(?<gate>Review): (?<status>waiting|approved)", "artefact": "PR.md" },
    "tasks":  { "file": "PLAN.md", "section": "Tasks", "count": "checkboxes" },
    "parked": { "state": "^(Parked|On hold)" },
  },
}
```

**A richer process: numbered builds with phases, lanes and sign-offs**

```json5
{
  "v": 1,
  "workflow": {
    // build/012-checkout-flow branches; each build's notes live in docs/builds/012_*/
    "builds": { "from": "branches", "branch": "build/{num}-{slug}", "folder": "docs/builds/{num}_*" },
    "state":  { "file": "progress.md", "section": "Status", "pick": "first-quote" },
    "lane":   { "file": "progress.md", "match": "^Lane: (?<lane>\\w+)", "default": "standard" },
    "parked": { "state": "^(Parked|On hold)" },
    "closed": { "state": "^Done" },               // done but not merged → "needs you"
    "phases": {
      // "- [x] 2. Design (started 2026-09-30 → 2026-10-01)"
      "file": "progress.md", "section": "Phases",
      "list": "^- \\[(?<done>[ x])\\] (?<n>\\d)\\. (?<name>\\w+)(?: \\(started (?<started>[\\d-]+)(?: → (?<doneAt>[\\d-]+))?\\))?",
      "skip": { "lane": "quick", "phases": [2, 3] },
    },
    "gates": {
      // "- Design review: waiting since 2026-10-01 09:30"
      "file": "progress.md", "section": "Sign-offs",
      "list": "^- (?<gate>[\\w ]+): (?<status>waiting|approved)(?: since)? (?<at>.+)$",
      "phase": { "design review": 2, "qa": 4 },
      "artefact": { "design review": "design.md", "qa": "qa-notes.md" },
      "approve": "make sign-off GATE='{gate}' BUILD={num}",
    },
    "tasks": { "file": ["plan.md", "brief.md"], "section": "Tasks", "count": "checkboxes" },
  },
}
```

## Reference

### `builds`: what one build is (required)

| `from` | With | Each build is |
|---|---|---|
| `worktrees` | | a git worktree other than the main checkout. `num` is its folder name, `slug` its branch. |
| `branches` | `branch`: a pattern like `build/{num}-{slug}` or `feature/{slug}` | a local branch matching the pattern |
| `folders` | `folder`: a pattern like `docs/builds/{num}_{slug}` | a folder on the main checkout matching the pattern |

`builds.folder` (with `worktrees` or `branches`) is where a build's files live, relative to its checkout. It takes `{num}`, `{slug}` and `{branch}`, and its last part may use `*`, e.g. `docs/builds/{num}_*`. Without it, files are read from the checkout's root.

A branch that's merged leaves the list, unless it's still checked out in a worktree. Merged means its commits are in the local main branch (`main`, else `master`) or in origin's default branch as last fetched, or that merging it into origin's would change nothing because its changes went in as a squash or rebase. A brand-new branch looks merged to git, so worktrees always count. A build whose commits are all by someone else (not this clone's `user.email`) is a teammate's: if it's closed but not merged, it's shown for information, not as needing you.

With `branches`, builds that only exist as `origin/…` (pushed from another machine, or by a teammate) count too, if they've had a commit in the last 30 days. `"remote": true` counts all of them, and `"remote": false` none. Chief Stew never fetches, so these are as fresh as your last `git fetch`.

A worktree on a branch that doesn't match the pattern (an agent's worktree branched from a build, say) is attached to the build it's built on, so agents working there count for that build. A build checked out in a worktree is read from disk, so uncommitted edits show; otherwise it's read from git.

### Finding the text

Every field below says where to read:

- `file`: a path relative to the build's folder, or a list of paths (the first that exists wins). Paths can use `{num}`, `{slug}` and `{branch}`, e.g. `work/AC-{num}/brief.md`.
- `section` (optional): a markdown heading. Only the text under it is used, up to the next heading of the same or a higher level. It matches the start of the heading text, case-insensitively.

### Fields

| Field | How it reads | Becomes |
|---|---|---|
| `state` | `pick`: `first-line` (the default) or `first-quote` (the first `> ` blockquote); or `match`: a regex (named group `state`, else the first group) | the build's one-line status. Without it, the last commit subject is used. |
| `lane` | `match` (group `lane`), with an optional `default` | a route name, used by `phases.skip`. Shown on the build only when the file states it; the `default` picks the route but isn't shown. |
| `parked` | `state`: a regex on the state line | set aside: tagged parked, listed last, and doesn't need you |
| `closed` | `state`: a regex on the state line | finished but not merged: needs you |
| `phases` | `list`: `"checkboxes"` (each `- [ ]`/`- [x]` line is a phase), or a regex applied per line with groups `n`, `name`, `done` (`x` or `true` means done), `started`, `doneAt`. Optional `skip: { "lane": "fast", "phases": [2, 3] }`. | the phase dots. The first unfinished phase is active, or the one with a `started` time if your regex captures `started`. |
| `gates` | `list`: a regex per line with groups `gate`, `status` (words like waiting/open/pending, or approved/passed/done), `at`; or `"checkboxes"` (unticked means waiting). Optional `phase` (gate → phase number), `artefact` (one path template, or gate → path), and `approve` (a command template using `{gate}`, `{num}`, `{slug}`). | gates. A waiting gate **needs you**, with the artefact to open (a read-only copy from git when the build isn't checked out) and the approve command to copy (Chief Stew never runs it). |
| `tasks` | `count: "checkboxes"`, with an optional `phase`: the phase number the tasks belong to (or a list) | done / total, shown once at least one is done. With `phase`, shown only while that phase is active, so a finished plan's count doesn't follow the build into review |

Unknown keys are reported by `chiefstew check`, so a typo never silently does nothing.

Dates can be ISO 8601, `YYYY-MM-DD`, or `YYYY-MM-DD HH:MM` (local time).

### When a description isn't enough

Use a `"status"` command instead: an argv list for a program that prints contract JSON (`docs/event-contract.md` § 4). Use one or the other, not both.

## Roadmap: the plan around the builds

`workflow` finds builds in flight. A top-level `roadmap` (next to `workflow` or `status`, or on its own) says where the repo's plan is written down, so Chief Stew can also show what's finished, what's marked next and what's still to come. It's optional, and nothing else depends on it. A `.chiefstew.json` with only a `roadmap` watches the repo's agents (no build status) and shows its roadmap.

```json5
{
  "v": 1,
  "workflow": { /* … */ },
  "roadmap": {
    // docs/roadmap.md: "## Stage 2 · Checkout" headings and an "## Anytime pool", each with a table
    "file": "docs/roadmap.md",
    "group": { "match": "^(?<name>Stage \\d+|Anytime pool)" },
    "columns": { "num": "#", "name": "Build", "status": "Status" },
    "status": {
      "done": "^Done(?: (?<date>[\\d-]+))?",
      "folded": "^Merged into",
      "dropped": "^Dropped",
      "active": "^In progress",
      "next": "^(Next|Ready)",
      "planned": "^(Planned|Later)",
    },
  },
}
```

```markdown
## Where we are

### Sequencing

| #   | Build         | Status      |    ← skipped: no heading above it matches group.match
| --- | ------------- | ----------- |
| 013 | saved_cards   | Next        |

## Stage 2 · Checkout

| #   | Build          | Status                       |
| --- | -------------- | ---------------------------- |
| 011 | cart_summary   | **Done 2026-09-12**          |
| 012 | checkout_flow  | In progress                  |
| 013 | saved_cards    | Next (waits for 012)         |
| 014 | gift_wrap      | Merged into 011              |
| —   | promo_codes    | idea, not numbered yet       |
```

### Keys

| Key | Required | Meaning |
|---|---|---|
| `file` | yes | A markdown file, relative to the repo root, read from git (contract §4c says which branch). 256 KB at most; a bigger file is reported, not cut short. |
| `section` | no | Only read under this heading (§ Finding the text; it matches the start of the heading text, so `Stage 1` also matches `Stage 10`). |
| `group.match` | no | A regex on heading text, at any level. A table belongs to the closest heading above it that matches, looking only at the headings it sits under (the nearest heading at each higher level). A table with no matching heading above it is skipped. A named group `name` gives the name shown; otherwise the whole heading is used. A regex can have only one group called `name`, so for several kinds of heading, choose them with a lookahead: `^(?=Stage|Pool)(?:Stage \\d+: )?(?<name>[^·]+)`. Without `group`, every table is read as one group. |
| `columns` | yes | The header text of the `num` column (required), and of `name` and `status`, matched case-insensitively after trimming. A table is read only if its header has every column named here. |
| `status` | no | Regexes on the status text: `dropped`, `folded`, `done`, `active`, `next`, `planned`, tried in that order, first match wins. A named group `date` (ISO 8601 or `YYYY-MM-DD`) on `done` dates the row. Text that matches none of them, or an empty cell, means **planned** as well; a `planned` rule says that's meant, so `chiefstew check` lists only status text no rule explains. |

Every cell is read as plain text: markdown emphasis, code and links are removed before anything is matched. Headings and tables inside ``` fences are ignored. A row's `num` must look like an ID (letters, digits, `.`, `_`, `-`, starting with a letter or digit). A row whose `num` doesn't (empty, `—`, `TBD`) is kept as **unnumbered**: it's shown in its group, never joined to status and never treated as a duplicate.

### What each row becomes

| In the file | In Chief Stew |
|---|---|
| A `num` that status also reports | **Now**, live from status: phases, gates, agents. The file's status is ignored. Parked builds and teammates' builds keep their labels. |
| `active`, but status doesn't report it | "In progress in the plan, not in status": the file and status disagree, so it's shown under Now and flagged. |
| `next` | **Up next**, in file order, with its status text as written |
| `done` | Done, in its group. Newest first under **Shipped** when its whole group is done or folded. |
| `folded` | Hidden unless asked for, with its status text as written ("Merged into 011") |
| `dropped` | Hidden unless asked for |
| `planned`, or anything else | Planned, in file order within its group, with its status text as written |

Groups show their own heading and counts, e.g. "Stage 2 · Checkout: 1 done, 2 to do". Chief Stew doesn't label a group as complete or under way, never reorders a plan, and never predicts a date. The status text is shown as the file writes it (one line, cut short, the whole of it on hover), because that's where a plan says things like "waits for 012".

Builds found with `builds.from: worktrees` use the worktree's folder name as their `num`, so they join to roadmap rows only if folder names and row IDs agree.

If a `num` appears twice in groups that are read, the first row wins, and both `chiefstew check` and the roadmap say where the second one is. `chiefstew check` also lists, per group, the rows read; the tables skipped and why; status text that matched no rule; unnumbered rows; and unknown keys, including misspelled top-level ones (`roadmp`).

## Safety

The engine only reads files inside the repo and its worktrees (256 KB at most each) and runs a fixed set of read-only git commands (`worktree list`, `for-each-ref`, `log`, `show`, `cat-file`, `ls-tree`, `rev-parse`, `symbolic-ref`, `config`, `remote`, `merge-base`, `merge-tree`, `diff`, `rev-list`) with `GIT_OPTIONAL_LOCKS=0`. Nothing from the repo is executed.
