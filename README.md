# Chief Stew

A macOS menu-bar app that shows, live, what your coding agents and builds are doing, and **what needs you**: a Claude session asking a question or waiting for permission, a build waiting for your sign-off, finished work that isn't merged. Everything else stays quiet, so you can do other things while they run.

- Works with **any git repo**. With no setup, it shows each repo's agents. A repo that adds a read-only status command also gets its builds, phases, gates and leftovers.
- **Local only:** no network listeners, no telemetry. It never changes your repos.
- macOS 14+, Swift only. Built from source with one command.

## Install

```sh
git clone <this repo> ~/Developer/chiefstew
cd ~/Developer/chiefstew
./build.sh install
```

This needs Xcode or the Command Line Tools. It builds a release copy, installs it to `/Applications/Chief Stew.app` and opens it. Then:

1. **Allow notifications** when macOS asks.
2. Click the ferry in the menu bar, then **Add a repo…**. The wizard takes about a minute:
   - **Choose a repo**, existing or brand new; it just needs to be a git repo.
   - **Install hooks:** one click adds Claude Code hooks to `~/.claude/settings.json`, backed up first. Every repo then reports when an agent needs you. No repo changes.
   - **Build status (optional):** pick your coding agent under **Run setup prompt**. Claude Code, Codex, Gemini and others are found automatically, and **Copy setup prompt** works with anything else. It opens in Terminal in that repo, studies how the repo tracks its work, and describes it in `.chiefstew.json` as data, not code. It checks the result with `chiefstew check` until it's right. The wizard shows the result live, for example "2 builds · phases ✓ · gates ✓ · tasks ✓". With no agent, **Start basic** writes a one-line starter (one build per worktree or branch). Either way the file is left uncommitted for you to review.
3. In **Settings… → General**, turn on **Launch at login**, and choose the app **Open worktree** should use.

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

## Update

When `main` in your clone has new commits, the panel shows **Update available** and you get one notification. Click either to build and install the update; Chief Stew restarts when it's done. It always builds a clean export of `main` (`./build.sh update`), never a branch or uncommitted edits you have checked out. If the build fails, the old copy keeps running (or is put back), and the panel shows **Try again** and **Open log** (`~/Library/Logs/Chief Stew/update.log`).

- **By hand:** `./build.sh install`
- **Undo:** `./build.sh rollback`. The three newest copies are kept in `~/Library/Application Support/Chief Stew/backups/`.

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
