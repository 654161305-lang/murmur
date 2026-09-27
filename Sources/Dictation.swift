import AVFoundation
import Speech

enum DictationError: LocalizedError {
    case recognizerUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let l): return "Speech recognition isn't available for \(l)."
        }
    }
}

/// Streams microphone audio into Apple's speech recognizer (on-device when supported).
final class Dictation {
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
    private var finishHandler: ((String, [Float]) -> Void)?
    // 16 kHz mono copy of the recording, for Whisper.
    private var converter: AVAudioConverter?
    private let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let samplesLock = NSLock()

    var onLevel: ((CGFloat) -> Void)?

    static func requestPermissions(_ done: @escaping (_ mic: Bool, _ speech: Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { done(mic, status == .authorized) }
            }
        }
    }

    /// Starts recording. Apple's recognizer runs alongside (as Whisper's backup) when available;
    /// it is only required when `requireApple` is set.
    func start(locale: String, vocabulary: [String], requireApple: Bool) throws {
        latestText = ""
        samplesLock.lock(); samples.removeAll(); samplesLock.unlock()

        let rec = SFSpeechRecognizer(locale: Locale(identifier: locale))
        if let rec, rec.isAvailable {
            recognizer = rec
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
            req.contextualStrings = Array(vocabulary.prefix(100))
            request = req
        } else if requireApple {
            throw DictationError.recognizerUnavailable(locale)
        } else {
            request = nil
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: whisperFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.capture(buffer)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let level = CGFloat(min(1, rms * 14))
            DispatchQueue.main.async { self.onLevel?(level) }
        }

        engine.prepare()
        try engine.start()

        guard let rec = recognizer, let req = request else { return }
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latestText = result.bestTranscription.formattedString
                    if result.isFinal { self.complete() }
                }
                if error != nil { self.complete() }
            }
        }
    }

    /// Stops listening and delivers Apple's transcript plus the 16 kHz samples.
    /// With `waitForFinal` false (Whisper mode) it returns at once, using Apple's latest partial as the backup.
    func stop(waitForFinal: Bool, _ completion: @escaping (String, [Float]) -> Void) {
        finishHandler = completion
        stopAudio()
        if !waitForFinal {
            let t = task
            complete()
            t?.cancel()
        } else if let request {
            request.endAudio()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.complete() }
        } else {
            complete()
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0] else { return }
        samplesLock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        samplesLock.unlock()
    }

    func cancel() {
        finishHandler = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func complete() {
        guard let handler = finishHandler else { return }
        finishHandler = nil
        task = nil
        request = nil
        samplesLock.lock(); let audio = samples; samplesLock.unlock()
        handler(latestText, audio)
    }
}
