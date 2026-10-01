import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
}

/// Runs a child process off the main thread, with a timeout. No shell is involved.
public enum CommandRunner {
    public static func run(
        _ executable: String, _ arguments: [String], cwd: String? = nil,
        environment: [String: String]? = nil, timeout: TimeInterval
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                do {
                    cont.resume(
                        returning: try runBlocking(
                            executable, arguments, cwd: cwd, environment: environment,
                            timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public static func runBlocking(
        _ executable: String, _ arguments: [String], cwd: String?,
        environment: [String: String]?, timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Collect output as it arrives instead of waiting for EOF: a background process the
        // child started can inherit the pipes and keep them open forever (review:
        // concurrency-1). Completion is keyed on the child exiting, plus a short grace period.
        let outData = Box(Data())
        let errData = Box(Data())
        let drained = DispatchGroup()
        for (pipe, box) in [(out, outData), (err, errData)] {
            drained.enter()
            let once = Box(false)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if !once.get() {
                        once.set(true)
                        drained.leave()
                    }
                } else {
                    box.set(box.get() + chunk)
                }
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // The child is gone. Give the pipes a moment to deliver what it wrote, then stop
        // listening even if a grandchild still holds them.
        if drained.wait(timeout: .now() + 1) == .timedOut {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        return CommandResult(
            exitCode: process.terminationStatus, stdout: outData.get(), stderr: errData.get(),
            timedOut: timedOut)
    }
}

/// The login shell's `PATH` (and `node`, if there is one), found once. A GUI app starts with
/// launchd's minimal PATH, so this asks `$SHELL -l` (docs/event-contract.md § 6). Node is only
/// needed by repos whose command starts with `node`.
public struct LoginEnvironment: Sendable, Equatable {
    public var node: String?
    public var path: String
    public var nodeVersion: String?

    public init(node: String?, path: String, nodeVersion: String?) {
        self.node = node
        self.path = path
        self.nodeVersion = nodeVersion
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let detail): "couldn't read the login shell's PATH (\(detail))"
            }
        }
    }

    /// `nodeOverride` skips the shell lookup for `node` (a settings value).
    public static func resolve(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        nodeOverride: String? = nil
    ) async throws -> LoginEnvironment {
        let marker = "__CHIEFSTEW__"
        let script = "printf '\\n\(marker)%s\(marker)%s\(marker)\\n' \"$(command -v node)\" \"$PATH\""
        let r = try await CommandRunner.run(shell, ["-l", "-c", script], timeout: 15)
        let text = String(decoding: r.stdout, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 4 else {
            throw Failure.notFound(r.timedOut ? "timed out" : "exit \(r.exitCode)")
        }
        let path = parts[2]
        guard let node = nodeOverride ?? (parts[1].isEmpty ? nil : parts[1]) else {
            return LoginEnvironment(node: nil, path: path, nodeVersion: nil)
        }
        let v = try? await CommandRunner.run(node, ["--version"], timeout: 10)
        let version = v.map {
            String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return LoginEnvironment(node: node, path: path, nodeVersion: version?.isEmpty == false ? version : nil)
    }

    /// `v24.21.0` → 24.
    public static func majorVersion(_ version: String) -> Int? {
        let digits = version.drop { $0 == "v" }.prefix { $0.isNumber }
        return Int(digits)
    }
}
