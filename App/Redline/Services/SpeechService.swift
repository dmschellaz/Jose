import AVFoundation
import CoreMedia
import RedlineCore
import Speech

/// Converts mic buffers to the analyzer's format on the audio thread.
private final class AudioPipe: @unchecked Sendable {
    let converter: AVAudioConverter
    let outFormat: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var loggedError = false
    /// Audio-thread only: finds the end of each utterance so the recognizer can finalize at once.
    private var detector = SilenceDetector()
    /// Seconds of audio handed to the analyzer so far (its timeline starts at 0).
    private var fedSeconds: Double = 0
    /// Called on the audio thread with the analyzer-timeline time the speech stopped.
    let onUtteranceEnd: @Sendable (Double) -> Void
    /// Read on the audio thread: closed while Chatty speaks, plus a short tail.
    let gate: MicGate

    init?(from inFormat: AVAudioFormat, to outFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
          gate: MicGate, onUtteranceEnd: @escaping @Sendable (Double) -> Void) {
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        self.converter = converter
        self.outFormat = outFormat
        self.continuation = continuation
        self.gate = gate
        self.onUtteranceEnd = onUtteranceEnd
    }

    /// Zeroes every sample but keeps the length, so the analyzer's timeline stays in step with the clock.
    private static func silence(_ buffer: AVAudioPCMBuffer) {
        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            if !loggedError {
                loggedError = true
                NSLog("Redline: audio conversion failed: \(error)")
            }
        } else if out.frameLength > 0 {
            // While Chatty speaks, its voice is replaced by silence (not dropped) so it is never transcribed.
            let listening = gate.isListening()
            if !listening { Self.silence(out) }
            let start = fedSeconds
            continuation.yield(AnalyzerInput(buffer: out))
            fedSeconds += Double(out.frameLength) / outFormat.sampleRate
            if let channel = buffer.floatChannelData?[0] {
                let level = listening
                    ? SilenceDetector.level(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                    : -120
                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                if let end = detector.feed(level: level, at: start, duration: duration) { onUtteranceEnd(end) }
            }
        }
    }
}

enum SpeechServiceError: LocalizedError {
    case noAudioFormat, converterUnavailable
    var errorDescription: String? {
        switch self {
        case .noAudioFormat: "Speech recognition isn't available for this language."
        case .converterUnavailable: "Couldn't read the microphone."
        }
    }
}

@MainActor
final class SpeechService: SessionService {
    var onPartial: (@MainActor (String) -> Void)?
    /// Closed by VoiceService while Chatty speaks, so Redline's own voice isn't transcribed.
    let gate = MicGate()

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Installed from a nonisolated context so the tap closure isn't inferred @MainActor
    /// (AVAudioEngine invokes it on its own audio thread).
    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, pipe: AudioPipe) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in pipe.push(buffer) }
    }

    func start(context: SessionContext) async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()   // first run only: downloads the on-device model
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechServiceError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let emit = context.emit
        let clock = context.clock
        // Set after the engine starts so sentence times aren't shifted early by start-up latency.
        let offsetBox = OffsetBox()

        self.analyzer = analyzer
        self.continuation = continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self?.onPartial?("")
                        // Skip empty or punctuation-only finals (e.g. "." for a stretch of silence).
                        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { continue }
                        let start = result.range.start.seconds, end = result.range.end.seconds
                        guard start.isFinite, end.isFinite else { continue }   // NaN would break JSON encoding
                        let offset = offsetBox.value
                        emit(.sentence(id: UUID(), text: text,
                                       start: offset + start,
                                       end: offset + end))
                    } else {
                        self?.onPartial?(text)
                    }
                }
            } catch {
                NSLog("Redline: transcription ended: \(error)")
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)

            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            // Finalize as soon as the speaker pauses: on its own the recognizer waited 4–10 s.
            let finalizer = AnalyzerBox(analyzer)
            guard let pipe = AudioPipe(from: inFormat, to: format, continuation: continuation, gate: gate, onUtteranceEnd: { end in
                Task { await finalizer.finalize(through: end + 0.15) }
            }) else {
                throw SpeechServiceError.converterUnavailable
            }
            Self.installTap(on: input, format: inFormat, pipe: pipe)
            engine.prepare()
            offsetBox.value = clock.now()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            self.analyzer = nil
            self.continuation = nil
            resultsTask = nil
            throw error
        }
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("Redline: finalize failed: \(error)")
            await analyzer?.cancelAndFinishNow()
            resultsTask?.cancel()
        }
        await resultsTask?.value
        analyzer = nil
        continuation = nil
        resultsTask = nil
        onPartial?("")
    }
}

private final class OffsetBox: @unchecked Sendable {
    var value: TimeInterval = 0
}

/// Lets the audio thread ask the analyzer to finalize what has been said so far.
private final class AnalyzerBox: Sendable {
    let analyzer: SpeechAnalyzer
    init(_ analyzer: SpeechAnalyzer) { self.analyzer = analyzer }
    func finalize(through seconds: Double) async {
        try? await analyzer.finalize(through: CMTime(seconds: seconds, preferredTimescale: 600))
    }
}
