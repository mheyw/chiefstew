@testable import ChiefStewCore
import Foundation
import Testing

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func status(_ name: String) throws -> StatusReport {
        try JSONDecoder().decode(StatusReport.self, from: data(name))
    }

    static func sweep(_ name: String) throws -> SweepReport {
        try JSONDecoder().decode(SweepReport.self, from: data(name))
    }
}

func iso(_ s: String) -> Date { LooseDate.parse(s)! }

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chiefstew-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func event(
    _ kind: String, at ts: String, session: String? = "s1", worktree: String? = nil,
    message: String? = nil
) -> Event {
    Event(
        ts: iso(ts), kind: kind, repo: "/Users/you/my-app", worktree: worktree, session: session,
        message: message)
}
