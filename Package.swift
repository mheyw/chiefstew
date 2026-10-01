// swift-tools-version:6.0
// Chief Stew: a macOS menu-bar app showing live build status. Build the .app with ./build.sh.

import PackageDescription

let package = Package(
    name: "chiefstew",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChiefStew", targets: ["ChiefStew"]),
        // Installed as Chief Stew.app/Contents/Helpers/chiefstew (named -cli here because
        // macOS filenames are case-insensitive and it would collide with ChiefStew).
        .executable(name: "chiefstew-cli", targets: ["chiefstew-cli"]),
    ],
    targets: [
        // Everything testable without a UI: paths, the event contract, the state reducer.
        .target(name: "ChiefStewCore"),
        // SwiftUI views: pure functions of a Board, so they can be rendered offscreen in tests.
        .target(name: "ChiefStewUI", dependencies: ["ChiefStewCore"]),
        // The MenuBarExtra app: wiring, polling and the inbox. Kept thin.
        .executableTarget(name: "ChiefStew", dependencies: ["ChiefStewCore", "ChiefStewUI"]),
        // `chiefstew hook …` for Claude Code hooks and `chiefstew emit …` for repo scripts.
        .executableTarget(name: "chiefstew-cli", dependencies: ["ChiefStewCore"]),
        .testTarget(
            name: "ChiefStewCoreTests", dependencies: ["ChiefStewCore"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "ChiefStewUITests", dependencies: ["ChiefStewCore", "ChiefStewUI"]),
    ]
)
