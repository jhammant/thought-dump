import AVFoundation
import Observation
import Speech

/// Listens and transcribes on this device (SpeechAnalyzer), showing the words as they arrive.
/// Audio never leaves the phone; only the finished text is sent to the Mac.
@MainActor
@Observable
final class Recorder {
    private(set) var isRecording = false
    private(set) var isPreparing = false
    private(set) var committed = ""
    private(set) var volatile = ""
    private(set) var level: Float = 0
    private(set) var startedAt: Date?
    var problem: String?

    var text: String {
        [committed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var duration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    static var canTranscribe: Bool { SpeechTranscriber.isAvailable }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    func start() async {
        guard !isRecording, !isPreparing else { return }
        problem = nil
        committed = ""
        volatile = ""
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Microphone access is off. Turn it on in Settings, or type instead."
            return
        }
        guard Recorder.canTranscribe else {
            problem = "On-device transcription isn't available here. Type instead."
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        do {
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-GB")
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await download.downloadAndInstall()   // first run only: the language model
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw RecorderError("No audio format for transcription")
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            input = continuation
            self.analyzer = analyzer
            try await analyzer.start(inputSequence: stream)

            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let words = String(result.text.characters)
                        await MainActor.run {
                            guard let self else { return }
                            if result.isFinal {
                                self.committed = [self.committed, words].filter { !$0.isEmpty }.joined(separator: " ")
                                self.volatile = ""
                            } else {
                                self.volatile = words
                            }
                        }
                    }
                } catch {
                    await MainActor.run { self?.problem = error.localizedDescription }
                }
            }

            let node = engine.inputNode
            let hardware = node.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: hardware, to: format) else {
                throw RecorderError("Can't convert the microphone's audio")
            }
            node.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [weak self] buffer, _ in
                let level = Recorder.level(of: buffer)
                if let converted = Recorder.convert(buffer, with: converter, to: format) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            startedAt = Date()
            isRecording = true
        } catch {
            problem = error.localizedDescription
            await teardown()
        }
    }

    /// Stops listening, waits for the last words, and returns the whole transcript.
    func stop() async -> String {
        guard isRecording else { return text }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        await teardown()
        return text
    }

    func cancel() async {
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        await teardown()
        committed = ""
        volatile = ""
    }

    private func teardown() async {
        analyzer = nil
        input = nil
        results = nil
        level = 0
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 50))   // roughly -55 dB…-5 dB → 0…1
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

struct RecorderError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
