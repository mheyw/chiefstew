// A stand-in status command that speaks docs/event-contract.md § 4–5, for running Chief Stew before a
// real repo supports `--json`. The state comes from ../demo-state: idle | progress | needs |
// left | broken.

import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const stateFile = join(root, "demo-state");
const state = existsSync(stateFile) ? readFileSync(stateFile, "utf8").trim() : "progress";
const [cmd] = process.argv.slice(2);
// Times are anchored to when the state was set (demo-state's mtime), like real stamps that
// don't move between polls; otherwise every poll would look like a new wait and re-notify.
const base = existsSync(stateFile) ? statSync(stateFile).mtimeMs : Date.now();
const ago = (min) => new Date(base - min * 60_000).toISOString();
const wt = (n) => join(root, ".worktrees", `build-${n}`);

const PHASES = ["Brief", "Requirements", "Design", "Plan", "Implement", "Review", "Retro"];
const phases = (statuses, startedMin) =>
  statuses.map((s, i) => ({
    n: i + 1,
    name: PHASES[i],
    status: s,
    startedAt: i === 0 ? ago(startedMin) : null,
    doneAt: null,
  }));

const b173 = {
  num: "173", slug: "search_index", branch: "build/173-search-index",
  worktree: wt(173), merged: false, lastCommitAt: ago(3), behind: 4, flags: [],
  state: "Phase 5 — Implement, step 3", lane: "full",
  phases: phases(["done", "done", "done", "done", "active", "pending", "pending"], 102),
  gates: [{ gate: "design", status: "approved" }, { gate: "plan", status: "approved" }],
  tasks: { done: 6, total: 11 },
  progress: join(root, "README.md"),
};
const b175 = {
  num: "175", slug: "copy_review", branch: "build/175-copy-review",
  worktree: wt(175), merged: false, lastCommitAt: ago(9), flags: [],
  state: "Phase 5 — Implement", lane: "fast",
  phases: phases(["done", "pending", "pending", "pending", "active", "pending", "pending"], 24),
  tasks: { done: 1, total: 4 },
};
const b174 = {
  num: "174", slug: "checkout_flow", branch: "build/174-checkout-flow",
  worktree: wt(174), merged: false, lastCommitAt: ago(14), flags: [],
  state: "Phase 4 ready — waiting on the Plan gate", lane: "full",
  phases: phases(["done", "done", "done", "active", "pending", "pending", "pending"], 180),
  gates: [
    { gate: "design", status: "approved", at: ago(120) },
    { gate: "plan", status: "waiting", at: ago(12), artefact: join(root, "README.md"),
      approve: "make approve GATE=plan BUILD=174" },
  ],
  tasks: { done: 0, total: 9 },
};
const b172 = {
  num: "172", slug: "bulk_actions", branch: "build/172-bulk-actions", worktree: wt(172),
  merged: false, lastCommitAt: ago(2 * 1440), flags: ["closed-unmerged", "idle"],
  state: "Closed 2026-09-28",
};

const builds = { idle: [], progress: [b173, b175], needs: [b174, b173, b172, b175], left: [b173] };

if (state === "broken") {
  console.error("fatal: not a git repository");
  process.exit(1);
}
if (cmd === "status") {
  console.log(JSON.stringify({ v: 1, generatedAt: ago(0), repo: root, builds: builds[state] ?? [] }, null, 2));
} else if (cmd === "sweep") {
  const left = state === "left";
  console.log(JSON.stringify({
    v: 1, generatedAt: ago(0), repo: root,
    databases: { checked: true, claimed: 2, leaked: left ? ["myapp_wt_fix_b"] : [] },
    routes: left ? [{ hostname: "fix-b.api.my-app.localhost", port: 4012, pid: 5512, reason: "process 5512 is gone" }] : [],
    processes: left ? [{ pid: 67816, cwd: join(root, ".worktrees/129"), command: "node server.js" }] : [],
    cleanup: ["make clean-dbs", "portless prune"],
    errors: [],
  }, null, 2));
} else {
  console.error("demo status: status | sweep");
  process.exit(2);
}
