import Foundation

/// A `StatusReport` back to contract JSON (§ 4), for `chiefstew status`. Optional fields that
/// are empty are left out, as the contract allows.
public enum StatusJSON {
    public static func encode(_ report: StatusReport, now: Date = Date()) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        // A start known only by its day stays a day: midnight would claim a time nobody wrote.
        func day(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: d)
        }
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
            if let v = b.budget {
                var budget: [String: Any] = ["hours": v.hours]
                if let label = v.label { budget["label"] = label }
                row["budget"] = budget
            }
            if let phases = b.phases {
                row["phases"] = phases.map { p -> [String: Any] in
                    var d: [String: Any] = ["n": p.n, "name": p.name, "status": p.status]
                    if let t = p.startedAt { d["startedAt"] = p.startedDateOnly ? day(t) : iso.string(from: t) }
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
            if let v = b.title { row["title"] = v }
            if let v = b.folder { row["folder"] = v }
            if let t = b.changedAt { row["changedAt"] = iso.string(from: t) }
            return row
        }
        return out
    }
}

/// A `Roadmap` as JSON, for `chiefstew roadmap`. Diagnostic only: not part of the contract.
public enum RoadmapJSON {
    public static func encode(_ r: Roadmap) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func row(_ x: Roadmap.Row) -> [String: Any] {
            var d: [String: Any] = ["num": x.num ?? NSNull(), "name": x.name, "status": x.status.rawValue, "text": x.text, "line": x.line]
            if let t = x.date { d["date"] = iso.string(from: t) }
            return d
        }
        var out: [String: Any] = [
            "file": r.file, "ref": r.ref, "fromOrigin": r.fromOrigin, "bytes": r.bytes,
            "groups": r.groups.map { ["name": $0.name, "line": $0.line, "rows": $0.rows.map(row)] as [String: Any] },
            "skipped": r.skipped.map { ["line": $0.line, "reason": $0.reason] as [String: Any] },
            "duplicates": r.duplicates.map { ["num": $0.num, "line": $0.line, "firstLine": $0.firstLine] as [String: Any] },
        ]
        if let t = r.fetchedAt { out["fetchedAt"] = iso.string(from: t) }
        return out
    }
}
