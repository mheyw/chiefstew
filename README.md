# Chief Stew

A macOS menu-bar app that shows, live, what your coding agents and builds are doing, and **what needs you**: a Claude session asking a question or waiting for permission, a build waiting for your sign-off, finished work that isn't merged. Everything else stays quiet, so you can do other things while they run.

- Works with **any git repo**. With no setup, it shows each repo's agents. A repo that adds a read-only status command also gets its builds, phases, gates and leftovers.
- **The window** (⌘O from the panel) shows a repo's **roadmap**, read from the plan it already keeps (what's in flight, what's marked next, what's still to come and what's shipped), and the full detail of anything left behind. Set one up with `chiefstew prompt roadmap`, or **Copy roadmap setup prompt** in the window.
- **Local only:** no network listeners, no telemetry. It never changes your repos.
- macOS 14+, Swift only. Built from source with one command.

## Install

You need macOS 14+ and Apple's Command Line Tools (`xcode-select --install`, about 5 minutes; Xcode works too). Then:

```sh
git clone https://github.com/mheyw/chiefstew.git ~/Developer/chiefstew
cd ~/Developer/chiefstew
./build.sh install
```

Chief Stew is built on your Mac, so there's no Apple account or notarization involved and no Gatekeeper warnings. It installs to `/Applications/Chief Stew.app` and opens. Then:

1. **Allow notifications** when macOS asks.
2. Click the ferry in the menu bar, then **Add a repo…**. The wizard takes about a minute:
   - **Choose a repo** (existing or brand new; it just needs to be a git repo). It's added straight away, and Chief Stew starts showing its agents.
   - **Install hooks:** one click adds Claude Code hooks to `~/.claude/settings.json`, backed up first. Every repo then reports when an agent needs you. No repo changes.
   - **Build status (optional):** pick your coding agent under **Run setup prompt**. Claude Code, Codex, Gemini and others are found automatically, and **Copy setup prompt** works with anything else. The agent studies how the repo tracks its work and describes it in `.chiefstew.json` (data, not code). If the repo records little, it offers to add a light structure and asks first. The wizard shows the result live. **Start basic** is the no-agent option. Files are left uncommitted for you to review.
3. In **Settings… → General**, turn on **Launch at login** and choose the app for **Open worktrees in**.

Downloaded a zip instead of cloning? That works too (`./build.sh install` in the unzipped folder). It just can't update itself; clone the repo when you want automatic updates.

## Updates

Chief Stew keeps itself up to date from the git clone you installed from. It checks the repo for a newer **release** (a `vX.Y.Z` tag) when it starts, when it wakes, when you open the panel, and hourly. It builds the release in the background (about a minute), installs it the moment the panel isn't open, restarts by itself (reopening Settings if you had it open) and tells you what changed. If anything fails, the current copy keeps running and the panel offers **Try again** and **Open log**.

- **Settings… → General → Updates:** choose Install automatically (the default), Ask first, or Don't check, and Releases (the default) or Latest main (for whoever develops Chief Stew). **Check now** checks and installs straight away.
- Checking reads only Chief Stew's own repo on GitHub, using your normal git access. Offline, or without access, it simply doesn't update; nothing else is affected.
- **By hand:** `./build.sh install` (your checkout) or `./build.sh update v0.3.0` (a release). **Undo:** `./build.sh rollback`.

## For maintainers: releasing

```sh
./release.sh 0.3.0
```

This runs the tests, sets `VERSION`, tags `v0.3.0` with the changes since the last release (which teammates see after updating), and pushes. Everyone on the Releases channel has it within the hour (or as soon as they open the panel). Push to `main` as often as you like in between: only tagged releases reach the team. GitHub Actions runs the tests on every push.

## Connect a repo by hand

Everything the wizard does can be done by hand; the contract is [docs/event-contract.md](docs/event-contract.md).

- **Build status:** describe the workflow in `.chiefstew.json` ([docs/workflow.md](docs/workflow.md)), then run `chiefstew check`:

  ```json5
  { "v": 1, "workflow": { "builds": { "from": "branches", "branch": "feature/{slug}" },
                          "phases": { "file": "PLAN.md", "section": "Phases", "list": "checkboxes" } } }
  ```

  `chiefstew init` writes a starter, and `chiefstew prompt | <your agent>` hands the job to an agent. If a description can't express your process, `"status": [argv…]` runs a command that prints JSON like §4 of the contract.

- **Instant updates from your scripts:** report phases and gates with the bundled command. It's a no-op for anyone without Chief Stew:

  ```sh
  CS="/Applications/Chief Stew.app/Contents/Helpers/chiefstew"
  [ -x "$CS" ] && "$CS" emit gate.waiting --build 012 --gate review --slug my_feature
  ```

- **Agent hooks:** Settings → General → Claude Code hooks → Install. This covers every repo.

## Uninstall

1. In **Settings… → General**, remove the **Claude Code hooks** and turn off **Launch at login**. Then quit from the panel.
2. Delete the app and its data:

   ```sh
   rm -rf "/Applications/Chief Stew.app" "$HOME/Library/Application Support/Chief Stew" \
     "$HOME/Library/Logs/Chief Stew" "$HOME/Library/Caches/Chief Stew"
   defaults delete com.mheyw.chiefstew
   ```

   If you've already deleted the app, the hooks do nothing, but you can remove the `# chiefstew` entries from `~/.claude/settings.json` by hand. Remove a leftover login item under System Settings → General → Login Items.

## Develop

- `swift test`: unit tests, contract tests, a workflow-engine test against a real temporary git repo, and offscreen UI snapshots (written to `$CHIEFSTEW_SNAPSHOTS`, default a temp folder).
- `dev/demo.sh needs`: runs against a fake repo, in the states idle, progress, needs, left and broken. `dev/demo.sh ask` / `answer` drop agent events. It uses `/tmp/chiefstew-demo`, so it never touches your real setup.
- `CHIEFSTEW_BUNDLE_ID=… ./build.sh`: builds under your own bundle ID.
- Notifications can't be tested from inside Claude Code's command sandbox; macOS denies them there.
- How it's put together: [docs/architecture.md](docs/architecture.md).
