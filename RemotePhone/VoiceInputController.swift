import AVFoundation
import Combine
import Speech

/// Captures speech on this iPhone only. It never sends audio or text to the Mac;
/// the session view decides what to do with a completed transcript.
@MainActor
final class VoiceInputController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case listening
        case finishing
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var message: String?

    private let backend: VoiceRecognitionBackend
    private var generation: UInt64 = 0
    private var completion: ((String?) -> Void)?
    private var recordingLimit: Task<Void, Never>?
    private var finalizationLimit: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    convenience init() { self.init(backend: AppleOnDeviceVoiceBackend()) }

    init(backend: VoiceRecognitionBackend) {
        self.backend = backend
    }

    var canFinish: Bool { phase == .listening || phase == .ready }

    #if DEBUG
    func loadNonRecordingPreview(_ text: String) {
        cancel()
        transcript = text
        phase = .ready
    }
    #endif

    func start(whileAllowed: @escaping @MainActor () -> Bool) async {
        guard phase == .idle, whileAllowed() else { return }
        generation &+= 1
        let current = generation
        transcript = ""
        message = nil
        phase = .requestingPermission

        do {
            try await backend.authorize(shouldContinue: { [weak self] in self?.generation == current })
            guard current == generation else { return }

            // A system permission alert temporarily makes the scene inactive.
            // Resume only after it returns to an authorized, active session.
            for _ in 0..<40 where !whileAllowed() {
                try? await Task.sleep(for: .milliseconds(100))
                guard current == generation else { return }
            }
            guard whileAllowed() else {
                backend.cancel()
                phase = .idle
                message = "Return to the active Mac session, then try the microphone again."
                return
            }

            try backend.begin(onResult: { [weak self] text, isFinal in
                self?.accept(text, isFinal: isFinal, generation: current)
            }, onFailure: { [weak self] in
                self?.fail(generation: current)
            })
            guard current == generation else { backend.cancel(); return }
            phase = .listening
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.interrupted(generation: current) }
            }
            recordingLimit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                self?.stopAtLimit(generation: current)
            }
        } catch {
            guard current == generation else { return }
            backend.cancel()
            phase = .idle
            message = (error as? VoiceInputError)?.errorDescription
                ?? "Voice input could not start. Try again."
        }
    }

    func finish(_ completion: @escaping (String?) -> Void) {
        guard canFinish else { return }
        self.completion = completion
        recordingLimit?.cancel()
        recordingLimit = nil
        if phase == .ready {
            complete()
            return
        }
        phase = .finishing
        backend.stop()
        let current = generation
        finalizationLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.generation == current else { return }
            self?.complete()
        }
    }

    func cancel() {
        generation &+= 1
        recordingLimit?.cancel()
        finalizationLimit?.cancel()
        recordingLimit = nil
        finalizationLimit = nil
        completion = nil
        removeInterruptionObserver()
        backend.cancel()
        transcript = ""
        message = nil
        phase = .idle
    }

    func pauseForInterruption() {
        guard phase == .listening else { return }
        generation &+= 1
        recordingLimit?.cancel()
        recordingLimit = nil
        removeInterruptionObserver()
        backend.cancel()
        phase = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .ready
        message = phase == .ready ? "Recording stopped. Tap Done to insert the text."
                                  : "Recording stopped. Try again."
    }

    private func accept(_ text: String, isFinal: Bool, generation current: UInt64) {
        guard current == generation, phase == .listening || phase == .finishing || phase == .ready else { return }
        transcript = text
        if isFinal {
            if phase == .finishing { complete() }
            else if phase == .listening {
                recordingLimit?.cancel()
                backend.stop()
                phase = .ready
                message = "Recognition finished. Tap Done to insert the text."
            }
        }
    }

    private func fail(generation current: UInt64) {
        guard current == generation, phase == .listening || phase == .finishing else { return }
        generation &+= 1
        recordingLimit?.cancel()
        finalizationLimit?.cancel()
        removeInterruptionObserver()
        backend.cancel()
        if phase == .finishing, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            complete()
        } else {
            completion = nil
            phase = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .ready
            message = phase == .ready ? "Voice recognition stopped. Tap Done to insert the text."
                                      : "Voice recognition stopped. Try again."
        }
    }

    private func stopAtLimit(generation current: UInt64) {
        guard current == generation, phase == .listening else { return }
        backend.stop()
        phase = .ready
        message = "Recording stopped after 45 seconds. Tap Done to insert the text."
    }

    private func complete() {
        guard phase == .finishing || phase == .ready else { return }
        finalizationLimit?.cancel()
        finalizationLimit = nil
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = completion
        completion = nil
        removeInterruptionObserver()
        backend.cancel()
        phase = .idle
        if value.isEmpty { message = "No words heard. Try again or type instead." }
        callback?(value.isEmpty ? nil : value)
    }

    private func interrupted(generation current: UInt64) {
        guard current == generation, phase == .listening || phase == .finishing else { return }
        if phase == .listening { pauseForInterruption() }
        else { fail(generation: current) }
    }

    private func removeInterruptionObserver() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }
}

@MainActor
protocol VoiceRecognitionBackend: AnyObject {
    func authorize(shouldContinue: @escaping @MainActor () -> Bool) async throws
    func begin(onResult: @escaping @MainActor (String, Bool) -> Void,
               onFailure: @escaping @MainActor () -> Void) throws
    func stop()
    func cancel()
}

private enum VoiceInputError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case onDeviceUnavailable
    case microphoneUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Allow microphone access in Settings to use voice input."
        case .speechDenied: "Allow speech recognition in Settings to use voice input."
        case .onDeviceUnavailable: "On-device voice input is unavailable for this iPhone language. You can still type."
        case .microphoneUnavailable: "The microphone is unavailable. Try again when it is free."
        case .cancelled: "Voice input was cancelled."
        }
    }
}

@MainActor
private final class AppleOnDeviceVoiceBackend: VoiceRecognitionBackend {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var microphoneTapped = false
    private var audioEnded = false
    private var sessionActive = false
    private var callbackGeneration: UInt64 = 0

    func authorize(shouldContinue: @escaping @MainActor () -> Bool) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceInputError.microphoneDenied
        }
        guard shouldContinue() else { throw VoiceInputError.cancelled }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard shouldContinue() else { throw VoiceInputError.cancelled }
        guard status == .authorized else { throw VoiceInputError.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: .current),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw VoiceInputError.onDeviceUnavailable
        }
        self.recognizer = recognizer
    }

    func begin(onResult: @escaping @MainActor (String, Bool) -> Void,
               onFailure: @escaping @MainActor () -> Void) throws {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw VoiceInputError.onDeviceUnavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        sessionActive = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
            throw VoiceInputError.microphoneUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        callbackGeneration &+= 1
        let current = callbackGeneration
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        microphoneTapped = true
        self.engine = engine
        self.request = request
        audioEnded = false
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.callbackGeneration == current else { return }
                if let result {
                    onResult(result.bestTranscription.formattedString, result.isFinal)
                }
                if error != nil { onFailure() }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            cancel()
            throw VoiceInputError.microphoneUnavailable
        }
    }

    func stop() {
        stopMicrophone()
        guard !audioEnded else { return }
        request?.endAudio()
        audioEnded = true
    }

    func cancel() {
        callbackGeneration &+= 1
        stopMicrophone()
        if !audioEnded { request?.endAudio() }
        audioEnded = true
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
    }

    private func stopMicrophone() {
        if microphoneTapped {
            engine?.inputNode.removeTap(onBus: 0)
            microphoneTapped = false
        }
        engine?.stop()
        engine = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}
