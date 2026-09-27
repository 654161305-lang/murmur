import Foundation

/// Runs the Python Whisper helper (whisper/murmur_whisper.py) as a long-lived child process,
/// so the model stays loaded between dictations.
final class WhisperEngine {
    enum Status { case notInstalled, loading, ready, failed(String) }

    private(set) var status: Status = .notInstalled
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pending: [(String?) -> Void] = []
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var warming = false

    static let venvPython = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Murmur/whisper-venv/bin/python")

    var isReady: Bool { if case .ready = status { return true } else { return false } }

    var statusText: String {
        switch status {
        case .notInstalled: return "Whisper not installed (run setup-whisper.sh)"
        case .loading: return "Whisper loading…"
        case .ready: return "Whisper ready · auto-detects language"
        case .failed(let why): return "Whisper failed: \(why)"
        }
    }

    func start() {
        guard FileManager.default.isExecutableFile(atPath: Self.venvPython.path),
              let script = Bundle.main.url(forResource: "murmur_whisper", withExtension: "py") else {
            status = .notInstalled
            diag("whisper: not installed")
            return
        }
        let p = Process()
        p.executableURL = Self.venvPython
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo")
        if FileManager.default.fileExists(atPath: cache.path) { env["HF_HUB_OFFLINE"] = "1" } // no network needed
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                diag("whisper: helper exited (\(proc.terminationStatus))")
                self.status = .failed("helper stopped")
                self.pending.forEach { $0(nil) }
                self.pending.removeAll()
            }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            status = .loading
            diag("whisper: loading model")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() { process?.terminate() }

    /// Wake model memory and GPU work while the user is speaking after an idle period.
    /// This is a separate protocol message, never a pending dictation callback.
    func prepareForRecording() {
        guard isReady, !warming, pending.isEmpty, let stdin,
              ProcessInfo.processInfo.systemUptime - lastActivity >= 60 else { return }
        warming = true
        diag("whisper: prewarming during recording")
        do {
            try stdin.write(contentsOf: Data("{\"warmup\":true}\n".utf8))
        } catch {
            warming = false
            diag("whisper: prewarm request failed")
        }
    }

    /// Transcribes 16 kHz mono float32 samples. Calls back on the main thread; nil means failure.
    func transcribe(_ samples: [Float], prompt: String, completion: @escaping (String?) -> Void) {
        guard isReady, let stdin else { completion(nil); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).f32")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do { try data.write(to: url) } catch { completion(nil); return }

        pending.append { text in
            try? FileManager.default.removeItem(at: url)
            completion(text)
        }
        let req: [String: Any] = ["path": url.path, "prompt": prompt]
        if var line = try? JSONSerialization.data(withJSONObject: req) {
            line.append(0x0A)
            stdin.write(line)
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if json["ready"] as? Bool == true {
                status = .ready
                lastActivity = ProcessInfo.processInfo.systemUptime
                diag("whisper: ready")
                continue
            }
            if json["warmed"] as? Bool != nil {
                warming = false
                lastActivity = ProcessInfo.processInfo.systemUptime
                diag(String(format: "timing: prewarm %.2fs (%@)",
                            json["seconds"] as? Double ?? 0,
                            json["warmed"] as? Bool == true ? "ready" : "failed"))
                continue
            }
            guard !pending.isEmpty else { continue }
            lastActivity = ProcessInfo.processInfo.systemUptime
            let done = pending.removeFirst()
            if let err = json["error"] as? String { diag("whisper: error \(err)"); done(nil); continue }
            diag("whisper: language=\(json["language"] as? String ?? "?")")
            if let seconds = json["seconds"] as? Double {
                diag(String(format: "timing: whisper %.2fs (%@)", seconds,
                            json["mode"] as? String ?? "silence"))
            }
            done(json["text"] as? String ?? "")
        }
    }
}
