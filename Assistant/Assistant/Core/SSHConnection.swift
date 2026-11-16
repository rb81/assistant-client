import Darwin
import Foundation

/// Owns one subprocess; the lock serializes launch/cancellation, not server state.
final class OwnedProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

    /// Uses a fixed executable and separate arguments, never a constructed local shell command.
    init(executable: URL, arguments: [String], output: Pipe? = nil, diagnostics: Pipe? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let output { process.standardOutput = output }
        else { process.standardOutput = FileHandle.nullDevice }
        if let diagnostics { process.standardError = diagnostics }
        else { process.standardError = FileHandle.nullDevice }
        process.terminationHandler = { [weak self] finished in
            self?.recordExit(finished.terminationStatus)
        }
    }

    /// Starts only if cancellation has not already won the launch race.
    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    /// Inspects only the subprocess created by this owner.
    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process.isRunning
    }

    /// Terminates only this client's child, including when an async task is cancelled.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.forceStop()
        }
    }

    /// Waits without blocking IO workers, including when the child exited before the waiter registered.
    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Resumes completion observers outside the lifecycle lock.
    private func recordExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    /// Reaps a tunnel and escalates only for an unresponsive owned process.
    func close() async {
        stop()
        for _ in 0..<20 {
            if !running { return }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        }
        forceStop()
    }

    /// Bounds cleanup if a helper ignores graceful termination.
    private func forceStop() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    deinit { stop() }
}

/// Enables synchronous child cleanup during application termination.
final class TunnelLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: OwnedProcess?

    /// Replaces the owned process under the lifecycle lock.
    func set(_ process: OwnedProcess?) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
    }

    /// Stops only this lifetime's SSH child.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.stop()
    }
}

/// Captures bounded handoffs and classifies diagnostics without exposing raw helper output.
enum ConnectionHelper {
    /// Completed streams keep credentials separate from bounded private diagnostics.
    private enum CapturePart: Sendable {
        case handoff(Data, Int32)
        case diagnostics(Data)
    }

    /// Runs discovery with cancellation, a deadline, and a strict 4 KiB output bound.
    static func capture(executable: URL, arguments: [String]) async throws -> Data {
        let pipe = Pipe()
        let diagnostics = Pipe()
        let child = OwnedProcess(executable: executable, arguments: arguments, output: pipe, diagnostics: diagnostics)
        return try await withTaskCancellationHandler {
            try child.start()
            return try await withThrowingTaskGroup(of: CapturePart.self) { group in
                group.addTask {
                    let output: Data = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            do {
                                var result = Data()
                                while let chunk = try pipe.fileHandleForReading.read(upToCount: 4097 - result.count),
                                      !chunk.isEmpty {
                                    result.append(chunk)
                                    guard result.count <= 4096 else {
                                        child.stop()
                                        throw ClientError.invalidDiscovery
                                    }
                                }
                                continuation.resume(returning: result)
                            } catch {
                                child.stop()
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                    return .handoff(output, await child.wait())
                }
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            do {
                                var result = Data()
                                while let chunk = try diagnostics.fileHandleForReading.read(upToCount: 1024),
                                      !chunk.isEmpty {
                                    result.append(chunk.prefix(max(0, 8192 - result.count)))
                                }
                                continuation.resume(returning: .diagnostics(result))
                            } catch {
                                child.stop()
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    child.stop()
                    throw ClientError.sshTimedOut
                }
                defer { group.cancelAll() }
                var handoff: (Data, Int32)?
                var diagnostic: Data?
                while let part = try await group.next() {
                    switch part {
                    case .handoff(let data, let status): handoff = (data, status)
                    case .diagnostics(let data): diagnostic = data
                    }
                    if let (data, status) = handoff, let diagnostic {
                        guard status == 0 else { throw failure(diagnostic, status: status) }
                        return data
                    }
                }
                throw ClientError.sshFailed
            }
        } onCancel: {
            child.stop()
        }
    }

    /// Only recognized failure categories reach the UI; arbitrary diagnostics remain private.
    private static func failure(_ diagnostic: Data, status: Int32) -> ClientError {
        let text = String(decoding: diagnostic, as: UTF8.self).lowercased()
        if text.contains("remote host identification has changed") { return .sshHostChanged }
        if text.contains("host key verification failed") { return .sshTrust }
        if text.contains("permission denied (") { return .sshAuthentication }
        if text.contains("could not resolve hostname") { return .sshResolution }
        if text.contains("no route to host") { return .sshNoRoute }
        if text.contains("connection refused") || text.contains("connection timed out") {
            return .sshUnreachable
        }
        if text.contains(".local/bin/assistant") {
            if text.contains("no such file") || text.contains("not found") { return .launcherMissing }
            if text.contains("permission denied") { return .launcherPermission }
        }
        if text.contains("install and start docker") || text.contains("docker: command not found") ||
            text.contains("docker: not found") { return .dockerMissing }
        if text.contains("docker is not accessible") || text.contains("cannot connect to the docker daemon") ||
            text.contains("permission denied") && text.contains("docker") { return .dockerUnavailable }
        if text.contains("service \"management\" is not running") || text.contains("service management is not running") {
            return .managementNotRunning
        }
        return .discoveryFailed(status)
    }
}

/// Allocates an ephemeral loopback port without selecting a public listening address.
enum LoopbackPort {
    /// Releases the reservation immediately before OpenSSH's checked bind.
    static func available() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientError.sshFailed }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { throw ClientError.sshFailed }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        guard result == 0 else { throw ClientError.sshFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Serializes tunnel ownership and discovery while API requests remain independently concurrent.
actor SSHConnection {
    private var tunnel: OwnedProcess?
    private nonisolated let lifetime = TunnelLifetime()
    private var generation = UUID()

    /// Common strict OpenSSH options preserve system configuration and agent authentication.
    static func arguments(for profile: ConnectionProfile) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
         "-o", "ConnectTimeout=10", "-p", String(profile.sshPort)]
    }

    /// Discovers credentials, opens the tunnel, and verifies the installation before returning it.
    func connect(_ profile: ConnectionProfile) async throws -> (HTTPManagementAPI, InstanceHealth) {
        try profile.validate()
        await disconnect()
        let current = UUID()
        generation = current
        let output: Data
        if profile.local {
            output = try await ConnectionHelper.capture(
                executable: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/assistant"),
                arguments: ["connect"]
            )
        } else {
            output = try await ConnectionHelper.capture(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: Self.arguments(for: profile) +
                    ["--", profile.host, "exec \"$HOME/.local/bin/assistant\" connect"]
            )
        }
        let discovery = try Wire.decoder().decode(ConnectionDiscovery.self, from: output)
        guard generation == current else { throw CancellationError() }
        try discovery.validate()
        let port = profile.local ? discovery.port : try LoopbackPort.available()
        if !profile.local {
            let child = OwnedProcess(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: Self.arguments(for: profile) + [
                    "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2", "-L",
                    "127.0.0.1:\(port):127.0.0.1:\(discovery.port)", "--", profile.host
                ]
            )
            try child.start()
            tunnel = child
            lifetime.set(child)
        }
        do {
            let api = try HTTPManagementAPI(port: port, token: discovery.token)
            for attempt in 0..<40 {
                guard generation == current else { throw CancellationError() }
                try Task.checkCancellation()
                do {
                    let health = try await api.read("health", as: InstanceHealth.self)
                    guard generation == current else { throw CancellationError() }
                    try health.validate(expectedInstance: profile.instanceID)
                    return (api, health)
                } catch let error as URLError where !profile.local && attempt < 39 {
                    guard tunnel?.running == true else { throw ClientError.sshFailed }
                    guard error.code == .cannotConnectToHost || error.code == .networkConnectionLost else { throw error }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw ClientError.sshTimedOut
        } catch {
            if generation == current { await disconnect() }
            throw error
        }
    }

    /// Disconnect never stops management or application services on the server.
    func disconnect() async {
        generation = UUID()
        let owned = tunnel
        tunnel = nil
        lifetime.set(nil)
        await owned?.close()
    }

    /// App termination cannot await an actor task before the process exits.
    nonisolated func terminate() {
        lifetime.stop()
    }
}
