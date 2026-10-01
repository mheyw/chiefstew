# Chief Stew

A macOS 14+ menu-bar app, Swift only (SwiftPM, no Xcode project). It shows, live, what the agents and builds in registered git repos are doing and what needs the owner. It's portable: any repo can take part through the contract, and nothing may assume a particular repo or one person's machine.

Read first:
- `README.md`: install, the Add Repo wizard, update, uninstall
- `docs/architecture.md`: how it works, the modules, and the decisions that hold
- `docs/event-contract.md`: the contract (`.chiefstew.json`, status and sweep JSON, events, the `chiefstew` command). Additive changes only; anything else bumps `v`.
- `docs/workflow.md`: the workflow description format (bundled into the setup prompt)

Rules:
- Never name, describe or use data from any private repo this tool was developed against: not in code, docs, tests, fixtures, examples or commit messages. Every example is invented (e.g. `my-app`, `feature/{slug}`).
- Chief Stew displays; it never runs builds, cleanup or anything that changes a watched repo.
- Local only: no network listeners, no telemetry.
- Don't re-open the decisions in `docs/architecture.md` without a new reason.

Build `./build.sh` · install `./build.sh install` · test `swift test` · demo `dev/demo.sh needs`. The installed app offers updates when `main` moves on. Notifications can't be tested from inside Claude Code's command sandbox, so run those checks with the sandbox off.
