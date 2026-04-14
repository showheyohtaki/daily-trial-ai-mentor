//
//  VoicevoxEngineManager.swift
//  leanring-buddy
//
//  Manages the lifecycle of a bundled VOICEVOX engine subprocess.
//  Starts the engine on app launch, polls until ready, and terminates
//  it on app exit. Skips launch if an external engine is already running
//  on the target port (e.g. user-launched VOICEVOX.app).
//
//  The engine binary and supporting files live in the app bundle at:
//    Clicky.app/Contents/Resources/vv-engine/
//

import Foundation

@MainActor
final class VoicevoxEngineManager {
    private var engineProcess: Process?
    private let host = "127.0.0.1"
    private let port = 50021
    private let session: URLSession

    /// Whether the manager started the engine (vs. finding an external one).
    private(set) var isManaged = false

    /// Whether the engine is responding to health checks.
    private(set) var isReady = false

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Starts the bundled VOICEVOX engine as a subprocess.
    /// If the port is already in use (external engine), skips launch and
    /// marks as ready immediately.
    func startEngine() async {
        // Check if something is already listening on the port
        if await checkHealth() {
            print("🟢 VOICEVOX engine already running on port \(port) (external)")
            isReady = true
            isManaged = false
            return
        }

        guard let engineURL = locateEngine() else {
            print("⚠️ VOICEVOX engine not found in app bundle")
            return
        }

        let runURL = engineURL.appendingPathComponent("run")

        // Verify the binary exists and is executable
        guard FileManager.default.isExecutableFile(atPath: runURL.path) else {
            print("⚠️ VOICEVOX engine binary not executable: \(runURL.path)")
            return
        }

        let process = Process()
        process.executableURL = runURL
        process.arguments = [
            "--host", host,
            "--port", String(port),
        ]
        // Set working directory to the engine folder so it finds its
        // relative paths (model/, speaker_info/, resources/, etc.)
        process.currentDirectoryURL = engineURL

        // Suppress engine stdout/stderr to avoid console noise.
        // The engine logs to stderr with uvicorn output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Set DYLD_LIBRARY_PATH so the engine finds its bundled dylibs
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = engineURL.path
        process.environment = env

        do {
            try process.run()
            engineProcess = process
            isManaged = true
            print("🚀 VOICEVOX engine started (PID \(process.processIdentifier))")
        } catch {
            print("⚠️ Failed to start VOICEVOX engine: \(error.localizedDescription)")
            return
        }
    }

    /// Polls the engine's /version endpoint until it responds with 200,
    /// or until the timeout elapses. Returns true if the engine is ready.
    func waitForReady(timeout: TimeInterval = 30) async -> Bool {
        // Already confirmed ready (e.g. external engine)
        if isReady { return true }

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await checkHealth() {
                isReady = true
                print("🟢 VOICEVOX engine ready")
                return true
            }

            // Check if the process crashed
            if isManaged, let process = engineProcess, !process.isRunning {
                print("⚠️ VOICEVOX engine process terminated unexpectedly (exit code \(process.terminationStatus))")
                return false
            }

            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }

        print("⚠️ VOICEVOX engine did not become ready within \(Int(timeout))s")
        return false
    }

    /// Terminates the engine subprocess if it was started by this manager.
    func stopEngine() {
        guard isManaged, let process = engineProcess, process.isRunning else {
            return
        }

        process.terminate()
        // Give it a moment to shut down gracefully
        process.waitUntilExit()
        print("🛑 VOICEVOX engine stopped (PID \(process.processIdentifier))")

        engineProcess = nil
        isManaged = false
        isReady = false
    }

    // MARK: - Private

    /// Locates the vv-engine directory inside the app bundle.
    private func locateEngine() -> URL? {
        // In the built app: Clicky.app/Contents/Resources/vv-engine/
        if let resourceURL = Bundle.main.resourceURL {
            let engineURL = resourceURL.appendingPathComponent("vv-engine")
            let runPath = engineURL.appendingPathComponent("run").path
            if FileManager.default.fileExists(atPath: runPath) {
                return engineURL
            }
        }

        // Development fallback: look for vv-engine in the project directory
        // (adjacent to the leanring-buddy source folder)
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // leanring-buddy/
            .deletingLastPathComponent()  // clicky/
            .appendingPathComponent("vv-engine")
        let devRunPath = devPath.appendingPathComponent("run").path
        if FileManager.default.fileExists(atPath: devRunPath) {
            print("📂 Using development vv-engine at: \(devPath.path)")
            return devPath
        }

        return nil
    }

    /// Checks if the engine is responding by hitting GET /version.
    private func checkHealth() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/version")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
