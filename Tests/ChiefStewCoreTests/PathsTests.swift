@testable import ChiefStewCore
import Foundation
import Testing

@Test func defaultHomeIsApplicationSupport() {
    let paths = Paths(environment: [:])
    #expect(paths.home.path.hasSuffix("/Library/Application Support/Chief Stew"))
    #expect(paths.inbox.lastPathComponent == "inbox")
    #expect(paths.heartbeat.lastPathComponent == "alive")
}

@Test func chiefstewHomeOverrides() {
    let paths = Paths(environment: ["CHIEFSTEW_HOME": "/tmp/cs-test"])
    #expect(paths.inbox.path == "/tmp/cs-test/inbox")
}
