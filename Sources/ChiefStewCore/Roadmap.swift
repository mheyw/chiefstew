import Foundation

// The roadmap: where a repo's plan is written down (contract § 4c, docs/workflow.md § Roadmap).
// Status covers builds in flight; the roadmap supplies the rest: what's finished, what's marked
// next and what's still to come. Like `workflow`, it's data and nothing in the repo runs.

/// What a roadmap row's status text says, in the order the rules are tried. Text that matches
/// no rule, or an empty cell, is `planned` too; a `planned` rule only says that's meant, so
/// `chiefstew check` doesn't list it as unexplained.
public enum RowStatus: String, Sendable, Equatable, CaseIterable, Codable {
    case dropped, folded, done, active, next, planned

    /// The rules a description can give, in the order they're tried.
    static let ruled: [RowStatus] = [.dropped, .folded, .done, .active, .next, .planned]
}

/// The top-level `"roadmap"` of `.chiefstew.json`.
public struct RoadmapSpec: Sendable, Equatable {
    public struct Columns: Sendable, Equatable {
        public var num: String
        public var name: String?
        public var status: String?
    }

    public var file: String
    public var section: String?
    /// A regex on heading text: a table belongs to the closest heading above it that matches.
    public var groupMatch: String?
    public var columns: Columns
    public var status: [RowStatus: String] = [:]

    public init(file: String, columns: Columns) {
        self.file = file
        self.columns = columns
    }

    /// Parses and checks the `roadmap` object, reporting every problem with its path.
    public static func parse(_ any: Any) -> Result<RoadmapSpec, WorkflowSpec.Problems> {
        var problems: [WorkflowSpec.Problem] = []
        func fail(_ path: String, _ message: String) { problems.append(.init(path: path, message: message)) }
        guard let o = any as? [String: Any] else {
            return .failure(.init(list: [.init(path: "roadmap", message: "must be an object")]))
        }
        func unknown(_ object: [String: Any], _ known: Set<String>, _ path: String) {
            for key in object.keys.sorted() where !known.contains(key) {
                fail("\(path).\(key)", "unknown key (known: \(known.sorted().joined(separator: ", ")))")
            }
        }
        func regex(_ value: Any?, _ path: String) -> String? {
            guard let value else { return nil }
            guard let pattern = value as? String, !pattern.isEmpty else {
                fail(path, "must be a regular expression")
                return nil
            }
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                fail(path, "not a valid regular expression")
                return nil
            }
            return pattern
        }
        unknown(o, ["file", "section", "group", "columns", "status"], "roadmap")

        let file = o["file"] as? String ?? ""
        if file.isEmpty || file.hasPrefix("/") || file.contains("..") {
            fail("roadmap.file", "a path relative to the repo root is required")
        }

        var columns = Columns(num: "")
        if let c = o["columns"] as? [String: Any] {
            unknown(c, ["num", "name", "status"], "roadmap.columns")
            if let num = c["num"] as? String, !num.trimmingCharacters(in: .whitespaces).isEmpty {
                columns.num = num
            } else {
                fail("roadmap.columns.num", "the header text of the column holding each row's ID is required")
            }
            columns.name = c["name"] as? String
            columns.status = c["status"] as? String
        } else {
            fail("roadmap.columns", "required: the header text of the table columns, e.g. { \"num\": \"#\", \"status\": \"Status\" }")
        }

        var spec = RoadmapSpec(file: file, columns: columns)
        if let s = o["section"] {
            if let s = s as? String { spec.section = s } else { fail("roadmap.section", "must be a heading's text") }
        }
        if let g = o["group"] {
            if let g = g as? [String: Any] {
                unknown(g, ["match"], "roadmap.group")
                spec.groupMatch = regex(g["match"], "roadmap.group.match")
                if g["match"] == nil { fail("roadmap.group.match", "required: a regular expression on heading text") }
            } else {
                fail("roadmap.group", "must be an object, e.g. { \"match\": \"^Stage \\\\d\" }")
            }
        }
        if let s = o["status"] {
            if let s = s as? [String: Any] {
                unknown(s, Set(RowStatus.ruled.map(\.rawValue)), "roadmap.status")
                for status in RowStatus.ruled {
                    if let r = regex(s[status.rawValue], "roadmap.status.\(status.rawValue)") { spec.status[status] = r }
                }
            } else {
                fail("roadmap.status", "must be an object of regular expressions")
            }
        }
        return problems.isEmpty ? .success(spec) : .failure(.init(list: problems))
    }
}

/// A repo's roadmap as read from its file: groups of rows, in the file's order.
public struct Roadmap: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        /// The row's ID, or nil when its cell doesn't look like one (`—`, empty, `TBD`).
        public var num: String?
        public var name: String
        public var status: RowStatus
        /// The status cell as plain text, as the file writes it.
        public var text: String
        /// From the `done` rule's `date` group.
        public var date: Date?
        /// 1-based line in the file.
        public var line: Int
    }

    public struct Group: Sendable, Equatable {
        /// The name shown: the `group.match` named group `name`, else the whole heading. Empty
        /// when the description has no `group` (every table is one group).
        public var name: String
        public var line: Int
        public var rows: [Row]
    }

    /// A table that wasn't read, and why.
    public struct Skipped: Sendable, Equatable {
        public var line: Int
        public var reason: String
    }

    public struct Duplicate: Sendable, Equatable {
        public var num: String
        public var line: Int
        public var firstLine: Int
    }

    public var groups: [Group] = []
    public var skipped: [Skipped] = []
    public var duplicates: [Duplicate] = []
    /// Status text that matched no rule (not even `planned`), so its row counts as planned.
    public var unmatched: [Row] = []

    /// Where it was read from (set by `RoadmapReader`).
    public var file = ""
    public var ref = ""
    public var blob = ""
    public var bytes = 0
    /// The ref is origin's: the roadmap is as fresh as this clone's last fetch.
    public var fromOrigin = false
    public var fetchedAt: Date?

    public var rows: [Row] { groups.flatMap(\.rows) }

    public init() {}
}

/// A roadmap that couldn't be read: shown on its own, never in place of status.
public struct RoadmapProblem: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public var hint: String?
    public var description: String { message }
}

// MARK: - Reading the markdown

public enum RoadmapParser {
    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$")

    /// Reads a roadmap from markdown text, as `spec` describes it.
    public static func parse(_ text: String, _ spec: RoadmapSpec) -> Roadmap {
        var roadmap = Roadmap()
        let lines = text.components(separatedBy: "\n")
        var range = 0..<lines.count
        if let section = spec.section {
            guard let r = sectionRange(lines, section) else {
                roadmap.skipped.append(.init(line: 1, reason: "no \"\(section)\" section"))
                return roadmap
            }
            range = r
        }
        let groupRe = spec.groupMatch.flatMap { try? NSRegularExpression(pattern: $0) }
        let statusRes = RowStatus.ruled.compactMap { s in
            spec.status[s].flatMap { try? NSRegularExpression(pattern: $0) }.map { (s, $0) }
        }
        var stack: [(level: Int, text: String, line: Int)] = []
        var fence: Substring?
        var firstLine: [String: Int] = [:]
        var i = range.lowerBound
        while i < range.upperBound {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code blocks: nothing inside them is a heading or a table.
            if let marker = fenceMarker(trimmed) {
                if let open = fence {
                    if marker.first == open.first && marker.count >= open.count { fence = nil }
                } else {
                    fence = marker
                }
                i += 1
                continue
            }
            if fence != nil {
                i += 1
                continue
            }
            if let (level, heading) = heading(line) {
                while let last = stack.last, last.level >= level { stack.removeLast() }
                stack.append((level, heading, i + 1))
                i += 1
                continue
            }
            guard trimmed.contains("|"), i + 1 < range.upperBound, isDelimiter(lines[i + 1]) else {
                i += 1
                continue
            }
            // A table: header, delimiter, then rows up to a blank line or a line with no pipe.
            let header = cells(line).map { plain($0).lowercased() }
            var body: [(line: Int, cells: [String])] = []
            var j = i + 2
            while j < range.upperBound {
                let l = lines[j]
                if l.trimmingCharacters(in: .whitespaces).isEmpty || !l.contains("|") { break }
                body.append((j + 1, cells(l)))
                j += 1
            }
            defer { i = j }
            let tableLine = i + 1
            let under = stack.last.map { "under \"\(plain($0.text))\"" } ?? "before any heading"

            // Its group: the closest heading above it that matches.
            var group = (name: "", line: 0)
            if let groupRe {
                guard let found = stack.reversed().lazy.compactMap({ h -> (name: String, line: Int)? in
                    groupName(plain(h.text), groupRe).map { ($0, h.line) }
                }).first else {
                    roadmap.skipped.append(.init(line: tableLine, reason: "\(under): no heading above it matches group.match"))
                    continue
                }
                group = found
            }

            func index(_ name: String) -> Int? { header.firstIndex(of: name.trimmingCharacters(in: .whitespaces).lowercased()) }
            let missing = [spec.columns.num, spec.columns.name, spec.columns.status].compactMap { $0 }.filter { index($0) == nil }
            if !missing.isEmpty {
                let has = header.filter { !$0.isEmpty }.joined(separator: ", ")
                roadmap.skipped.append(.init(
                    line: tableLine,
                    reason: "\(under): no \(missing.map { "\"\($0)\"" }.joined(separator: " or ")) column (has \(has))"))
                continue
            }
            let numCol = index(spec.columns.num)
            let nameCol = spec.columns.name.flatMap(index)
            let statusCol = spec.columns.status.flatMap(index)

            var rows: [Roadmap.Row] = []
            for (n, cells) in body {
                func cell(_ c: Int?) -> String { c.flatMap { cells.indices.contains($0) ? plain(cells[$0]) : nil } ?? "" }
                let rawNum = cell(numCol)
                let num = matches(idPattern, rawNum) ? rawNum : nil
                let text = cell(statusCol)
                var status = RowStatus.planned
                var date: Date?
                var matched = false
                for (s, re) in statusRes {
                    let ns = text as NSString
                    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
                    status = s
                    matched = true
                    if s == .done {
                        let r = m.range(withName: "date")
                        if r.location != NSNotFound { date = LooseDate.parse(ns.substring(with: r)) }
                    }
                    break
                }
                let row = Roadmap.Row(num: num, name: cell(nameCol), status: status, text: text, date: date, line: n)
                if let num {
                    if let first = firstLine[num] {
                        roadmap.duplicates.append(.init(num: num, line: n, firstLine: first))
                        continue
                    }
                    firstLine[num] = n
                }
                if !matched && !text.isEmpty { roadmap.unmatched.append(row) }
                rows.append(row)
            }
            // Tables under the same group heading add to it.
            if let last = roadmap.groups.last, last.name == group.name, last.line == group.line {
                roadmap.groups[roadmap.groups.count - 1].rows += rows
            } else {
                roadmap.groups.append(.init(name: group.name, line: group.line, rows: rows))
            }
        }
        return roadmap
    }

    /// The heading's display name if it matches: the named group `name`, else the heading.
    static func groupName(_ heading: String, _ re: NSRegularExpression) -> String? {
        let ns = heading as NSString
        guard let m = re.firstMatch(in: heading, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let r = m.range(withName: "name")
        return r.location != NSNotFound ? ns.substring(with: r).trimmingCharacters(in: .whitespaces) : heading
    }

    /// A heading whose text starts with `name` and the lines under it, up to the next heading of
    /// the same or a higher level (as `WorkflowEngine.section`), as a range of line indices. The
    /// heading is included: it can be the group its tables belong to.
    static func sectionRange(_ lines: [String], _ name: String) -> Range<Int>? {
        let want = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let start = lines.firstIndex(where: { heading($0).map { $0.text.lowercased().hasPrefix(want) } ?? false }),
            let level = heading(lines[start])?.level
        else { return nil }
        var end = start + 1
        while end < lines.count {
            if let h = heading(lines[end]), h.level <= level { break }
            end += 1
        }
        return start..<end
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    /// "```" or "~~~" (or longer) opening or closing a fenced block.
    static func fenceMarker(_ trimmed: String) -> Substring? {
        for c in ["`", "~"] as [Character] {
            let run = trimmed.prefix { $0 == c }
            if run.count >= 3 { return run }
        }
        return nil
    }

    static let delimiter = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)

    static func isDelimiter(_ line: String) -> Bool { line.contains("-") && matches(delimiter, line) }

    /// A table row's cells: split on `|`, except `\|` and pipes inside a code span.
    static func cells(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var code = false
        var escaped = false
        for ch in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                cur.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "`" {
                code.toggle()
                cur.append(ch)
            } else if ch == "|" && !code {
                out.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if escaped { cur.append("\\") }
        out.append(cur)
        // Outer pipes are optional: drop the empty cells they leave.
        if out.count > 1, out.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeFirst() }
        if out.count > 1, out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)

    /// A cell or heading as plain text: links become their text; emphasis, strikethrough and
    /// code marks go; whitespace is collapsed.
    public static func plain(_ s: String) -> String {
        let ns = s as NSString
        let unlinked = link.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
        return unlinked.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "").replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

// MARK: - Reading it from git

public enum RoadmapReader {
    /// The ref to read the roadmap from: the branch status judges "merged" against. That's
    /// origin's default when it contains the local default (it's fresher: nobody pulls main
    /// while on a build branch), else the local default. Never what's checked out.
    static func ref(_ git: GitReader) -> (ref: String, fromOrigin: Bool)? {
        let local = git.mainBranch()
        let hasLocal = local != "HEAD"
        let upstream = git.originDefault()
        switch (hasLocal, upstream) {
        case (true, let up?): return git.isMerged(local, into: up) ? (up, true) : (local, false)
        case (true, nil): return (local, false)
        case (false, let up?): return (up, true)
        case (false, nil): return nil
        }
    }

    /// The file's blob ID on the roadmap's ref: changes only when the file does, so a caller
    /// can skip re-reading it.
    public static func blob(repo: String, spec: RoadmapSpec) -> String? {
        let git = GitReader(repo: PathMatch.normalize(repo))
        guard let (ref, _) = ref(git) else { return nil }
        return git.run(["rev-parse", "--verify", "--quiet", "\(ref):\(spec.file)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func read(repo: String, spec: RoadmapSpec) -> Result<Roadmap, RoadmapProblem> {
        let git = GitReader(repo: PathMatch.normalize(repo))
        guard let (ref, fromOrigin) = ref(git) else {
            return .failure(.init(
                message: "no default branch to read \(spec.file) from",
                hint: "The roadmap is read from main (or master, or origin's default branch), and this repo has none."))
        }
        guard let blob = git.run(["rev-parse", "--verify", "--quiet", "\(ref):\(spec.file)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !blob.isEmpty
        else {
            return .failure(.init(
                message: "\(spec.file) isn't on \(ref)",
                hint: "The roadmap is read from \(ref) in git, so it must be committed there. Check the path in .chiefstew.json."))
        }
        let bytes = git.run(["cat-file", "-s", blob]).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard bytes <= WorkflowEngine.maxFile else {
            return .failure(.init(
                message: "\(spec.file) is \(bytes / 1024) KB; the limit is \(WorkflowEngine.maxFile / 1024) KB",
                hint: "Split the file, or point roadmap.section at the part with the plan."))
        }
        guard let text = git.run(["cat-file", "blob", blob]) else {
            return .failure(.init(message: "couldn't read \(spec.file) from \(ref)", hint: nil))
        }
        var roadmap = RoadmapParser.parse(text, spec)
        roadmap.file = spec.file
        roadmap.ref = ref
        roadmap.blob = blob
        roadmap.bytes = bytes
        roadmap.fromOrigin = fromOrigin
        if fromOrigin { roadmap.fetchedAt = git.fetchedAt() }
        return .success(roadmap)
    }
}

// MARK: - Joined with status

/// The roadmap with what status knows laid over it: what the window shows. Status wins for any
/// build it reports; the file supplies the rest. Nothing is inferred: groups keep the file's
/// order, and no group is labelled beyond its own name and counts.
public struct RoadmapPlan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var row: Roadmap.Row
        /// Status reports this build, so it's shown live from status, whatever the file says.
        public var live: Bool
    }

    public struct Group: Sendable, Equatable {
        public var name: String
        public var entries: [Entry]
        public var done: Int
        /// Planned, next and in progress (live or not).
        public var toDo: Int
        /// The newest `done` date in the group.
        public var latest: Date?
    }

    /// Builds status reports that are on the roadmap, by `num`, in the file's order.
    public var live: [String] = []
    /// Rows the file marks in progress that status doesn't report: the two disagree.
    public var disagreements: [Roadmap.Row] = []
    public var upNext: [Roadmap.Row] = []
    /// Groups with something still to do, in the file's order.
    public var groups: [Group] = []
    /// Groups with nothing to do and something done, newest first.
    public var shipped: [Group] = []
    /// Folded and dropped rows: hidden unless asked for.
    public var hidden: [Roadmap.Row] = []

    /// `liveNums`: the `num` of every build status reports (not merged).
    public static func join(_ roadmap: Roadmap, liveNums: Set<String>) -> RoadmapPlan {
        var plan = RoadmapPlan()
        for group in roadmap.groups {
            var g = Group(name: group.name, entries: [], done: 0, toDo: 0, latest: nil)
            for row in group.rows {
                let live = row.num.map(liveNums.contains) ?? false
                switch row.status {
                case .folded where !live, .dropped where !live:
                    plan.hidden.append(row)
                    continue
                case .done where !live:
                    g.done += 1
                    if let d = row.date, d > (g.latest ?? .distantPast) { g.latest = d }
                default:
                    g.toDo += 1
                }
                if live, let num = row.num { plan.live.append(num) }
                if !live && row.status == .active { plan.disagreements.append(row) }
                if !live && row.status == .next { plan.upNext.append(row) }
                g.entries.append(Entry(row: row, live: live))
            }
            if g.entries.isEmpty { continue }
            if g.toDo == 0 { plan.shipped.append(g) } else { plan.groups.append(g) }
        }
        // Newest first; groups without dates keep the file's order, after the dated ones.
        let dated = plan.shipped.enumerated().sorted { a, b in
            switch (a.element.latest, b.element.latest) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset < b.offset
            }
        }
        plan.shipped = dated.map(\.element)
        return plan
    }
}
