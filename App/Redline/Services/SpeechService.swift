import AVFoundation
import CoreMedia
import RedlineCore
import Speech

/// Converts mic buffers to the analyzer's format on the audio thread.
private final class AudioPipe: @unchecked Sendable {
    let converter: AVAudioConverter
    let outFormat: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation

    init?(from inFormat: AVAudioFormat, to outFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        self.converter = converter
        self.outFormat = outFormat
        self.continuation = continuation
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
        if error == nil, out.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: out))
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

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

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
        let offset = context.clock.now()
        let emit = context.emit

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self?.onPartial?("")
                        guard !text.isEmpty else { continue }
                        emit(.sentence(id: UUID(), text: text,
                                       start: offset + result.range.start.seconds,
                                       end: offset + result.range.end.seconds))
                    } else {
                        self?.onPartial?(text)
                    }
                }
            } catch {
                NSLog("Redline: transcription ended: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let pipe = AudioPipe(from: inFormat, to: format, continuation: continuation) else {
            throw SpeechServiceError.converterUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in pipe.push(buffer) }
        engine.prepare()
        try engine.start()

        self.analyzer = analyzer
        self.continuation = continuation
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        analyzer = nil
        continuation = nil
        resultsTask = nil
        onPartial?("")
    }
}
