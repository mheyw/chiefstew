import Foundation

/// The prompt the Add Repo wizard runs with the owner's coding agent inside a repo (or prints
/// with `chiefstew prompt`). The agent describes the repo's process in `.chiefstew.json`'s
/// `"workflow"` (data, not code), checks it with `chiefstew check`, and iterates. The contract
/// and the workflow format are included, so it works for a repo that has never heard of Chief Stew.
public enum SetupPrompt {
    public static func make(
        repo: String, config: RepoConfig, problem: String?, contract: String?, workflowDoc: String?,
        cli: String
    ) -> String {
        let name = URL(fileURLWithPath: repo).lastPathComponent
        var now: String
        switch config.source {
        case .none: now = "It has no `.chiefstew.json` yet, so Chief Stew only shows its agents."
        case .workflow: now = "It already has a `.chiefstew.json` workflow. Improve it."
        case .file: now = "It has a `.chiefstew.json` with a status command."
        }
        if let problem { now += " Last check: \(problem)" }
        let safe = cli.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
        let cs = safe ? cli : "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "'"

        return """
            Set up this repo (\(name)) for Chief Stew.

            Chief Stew is a macOS menu-bar app that shows, live, what's in flight in a repo and what needs the owner: a build waiting for sign-off, finished work that isn't merged, an agent asking a question. You'll describe how this repo tracks its work (and, if it tracks little, offer to add a light way to). Chief Stew reads the description and works the rest out. You don't write a program, and nothing in the repo is executed.

            Current state: \(now)

            Steps:

            1. **Study how the repo tracks work in flight.** Look at its branches and git worktrees (`git branch`, `git worktree list`), and at plan, progress or status files, task checklists, docs folders, agent instructions (CLAUDE.md, AGENTS.md) and CI config. Decide what one "build" is here: a feature branch, a worktree, or a folder per piece of work. For each build, find where the repo writes down its current state, its phases or steps, any sign-off point (a gate: review, approval, QA) and its tasks.

            2. **If the repo already records these, describe what's there** (step 3). Don't change its files.

            **If it records little or nothing, offer to add a little structure. Don't just describe the bare minimum.** Chief Stew is most useful when each build says where it's at and when it's waiting for the owner. Briefly tell the owner what they'd gain, then offer two or three options that fit how they already work, lightest first. For example:
               a. **Watch only:** one build per branch or worktree, with the last commit as its state. No changes to the repo.
               b. **A status file per build:** e.g. `STATUS.md` (or a folder per build) with a one-line state, a `Review: waiting` / `Review: approved` line for sign-off, and optionally task checkboxes.
               c. **A plan per build:** phases as checkboxes, tasks, and a sign-off line, for teams that work in stages.
               Then **ask the owner which they want, and wait for the answer.** Change nothing in the repo without their yes. If you can't ask (a non-interactive run), describe what exists (option a) and list the options in your summary.

               If they choose b or c:
               - Add a small template (e.g. `docs/templates/STATUS.md`), and fill one in for each build already in flight, from what you can see on its branch.
               - So it stays accurate, add a short section to the repo's agent instructions (`AGENTS.md` or `CLAUDE.md`; create `AGENTS.md` if there's neither). Tell agents to create the file when starting a build, update the state line as work moves, set the sign-off line to waiting when they need the owner, and tick tasks as they finish them. Keep it to a few lines, in the repo's own voice.
               - Leave everything uncommitted for review.

            3. **Write `.chiefstew.json`** at the repo root, as JSON5 (comments welcome). Put a `"workflow"` in it, as described in "The workflow format" below. Describe only what the repo really records, including any structure you added in step 2. Leave out anything the defaults already handle well.

            4. **Check it:** run `\(cs) check` in the repo. It prints every build it found, what it skipped and why, and for each field what matched and why anything didn't. Fix the description and run it again until it's right. **Read the skipped list too:** if it skipped something that's real work in flight, adjust the description so it's included (the reason says how). `\(cs) status` prints the exact JSON Chief Stew will show. If nothing is in flight right now, `check` still confirms the description is valid. To see the rules work on real data, try them on a branch you create in a scratch clone, then delete the clone.

            5. Only fall back to a `"status"` command (a program printing § 4 of the contract) if the process truly can't be described, and say why.

            6. Leave everything uncommitted, so the owner can review it. Tell them what you described, anything you added, and show the final `check` output.

            Notes:
            - Phases, gates and tasks are usually markdown: checkbox lines (`- [x] Design`) or lines like `Review: waiting`. Use `"list": "checkboxes"` for the first and a regular expression with named groups for the second. Group names: `n`, `name`, `done`, `started`, `doneAt` for phases; `gate`, `status`, `at` for gates.
            - `artefact` is the file a reviewer opens at a gate. `approve` is the exact command that signs a gate off, if the repo has one. Chief Stew copies it and never runs it.
            - `parked` (set aside) and `closed` (finished, waiting to merge) are regular expressions on the state line.

            What not to add (Chief Stew already covers it, and a second source makes it double up):
            - **No Claude Code hooks and no `agent.*` events.** Chief Stew's own hooks, installed once for every repo, already say when an agent needs the owner, ends a turn or gets an answer.
            - **No desktop notifications** from the repo's scripts while Chief Stew is running (the contract's `alive` file says when). Chief Stew decides what to notify.
            - **Optional:** if the repo has scripts that open or sign off a gate, they may also send `\(cs) emit gate.waiting` / `gate.approved` (contract § 2.1) so the change shows at once instead of at the next status read. Only facts the repo alone knows; never required.

            ---

            # The workflow format

            \(workflowDoc ?? "See docs/workflow.md in the Chief Stew repo.")

            ---

            # The contract (for reference: what `chiefstew status` produces)

            \(contract ?? "See docs/event-contract.md in the Chief Stew repo.")
            """
    }
}
