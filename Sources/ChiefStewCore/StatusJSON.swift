import Foundation

/// A `StatusReport` back to contract JSON (§ 4), for `chiefstew status`. Optional fields that
/// are empty are left out, as the contract allows.
public enum StatusJSON {
    public static func encode(_ report: StatusReport, now: Date = Date()) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = ["v": 1, "generatedAt": iso.string(from: now)]
        if let repo = report.repo { out["repo"] = repo }
        if let t = report.fetchedAt { out["fetchedAt"] = iso.string(from: t) }
        out["builds"] = report.builds.map { b -> [String: Any] in
            var row: [String: Any] = [
                "num": b.num, "slug": b.slug, "branch": b.branch, "state": b.state,
                "lastCommitAt": iso.string(from: b.lastCommitAt), "merged": b.merged,
                "worktree": b.worktree ?? NSNull(),
            ]
            if !b.worktrees.isEmpty { row["worktrees"] = b.worktrees }
            if let v = b.behind { row["behind"] = v }
            if !b.flags.isEmpty { row["flags"] = b.flags }
            if let v = b.lane { row["lane"] = v }
            if let v = b.parkedFlag { row["parked"] = v }
            if let phases = b.phases {
                row["phases"] = phases.map { p -> [String: Any] in
                    var d: [String: Any] = ["n": p.n, "name": p.name, "status": p.status]
                    if let t = p.startedAt { d["startedAt"] = iso.string(from: t) }
                    if let t = p.doneAt { d["doneAt"] = iso.string(from: t) }
                    if let s = p.skipped { d["skipped"] = s }
                    return d
                }
            }
            if !b.gates.isEmpty {
                row["gates"] = b.gates.map { g -> [String: Any] in
                    var d: [String: Any] = ["gate": g.gate, "status": g.status]
                    if let t = g.at { d["at"] = iso.string(from: t) }
                    if let v = g.phaseNumber { d["phase"] = v }
                    if let v = g.artefact { d["artefact"] = v }
                    if let v = g.artefactRef { d["artefactRef"] = v }
                    if let v = g.approve { d["approve"] = v }
                    return d
                }
            }
            if let t = b.tasks { row["tasks"] = ["done": t.done, "total": t.total] }
            if !b.urls.isEmpty { row["urls"] = b.urls }
            if let v = b.progress { row["progress"] = v }
            if let v = b.author { row["author"] = v }
            if let v = b.mine { row["mine"] = v }
            if let v = b.onlyOnOrigin { row["onlyOnOrigin"] = v }
            if let v = b.branchURL { row["branchURL"] = v }
            return row
        }
        return out
    }
}
