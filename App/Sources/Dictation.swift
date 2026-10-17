import AVFoundation
import Observation
import Speech

/// Speech-to-text for the ask box, on the device only: audio never leaves it, so dictation works
/// offline like the rest of ARC. Where on-device recognition isn't available the mic button is hidden.
@MainActor @Observable
final class Dictation {
    private(set) var isListening = false
    var error: String?

    // The documents are in English, so dictate in English whatever the device language.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.supportsOnDeviceRecognition == true }

    /// Officials' vocabulary the recognizer would otherwise mishear ("DSQ", not "D S Q").
    private static let vocabulary = [
        "TD", "DSQ", "DQ", "DNF", "DNS", "GS", "SL", "Super G", "DH", "Kombi", "EET", "OISRA", "ACR", "ICR",
        "FIS", "USSS", "TDTR", "Jury", "Referee", "Start Referee", "Finish Referee", "Chief of Course",
        "Chief of Race", "gate judge", "forerunner", "re-run", "hairpin", "delay gate", "vertical combination",
        "flush", "bib", "homologation", "seed points", "race penalty", "team captains' meeting", "course hold",
        "U10", "U12", "U14", "U16", "U18", "SafeSport",
    ]

    /// Starts listening; `onText` receives the whole transcription so far each time it improves.
    func start(onText: @escaping @MainActor (String) -> Void) async {
        guard !isListening, let recognizer, isAvailable else { return }
        guard await Self.authorize() else {
            error = "To dictate questions, allow ARC to use the microphone and speech recognition in Settings."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Self.vocabulary
        do {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            Self.installTap(on: engine.inputNode, feeding: request)
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self, onText: onText))
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // The audio tap and the recognition callback run off the main thread, so they're built in
    // nonisolated functions: closures formed in a main-actor method would assert they're on it.

    private nonisolated static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        return speech ? await AVAudioApplication.requestRecordPermission() : false
    }

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func resultHandler(
        for dictation: Dictation, onText: @escaping @MainActor (String) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak dictation] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                if let text { onText(text) }
                if done { dictation?.stop() }
            }
        }
    }
}
