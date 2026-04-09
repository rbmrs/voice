import Combine
import Foundation

struct WhisperLanguageOption: Identifiable, Hashable {
    let code: String
    let title: String

    var id: String { code }
}

enum PathValidationStatus {
    case valid
    case warning
    case invalid
}

struct PathValidation {
    let status: PathValidationStatus
    let message: String

    var isBlocking: Bool {
        status == .invalid
    }
}

enum RecordingTriggerMode: String, CaseIterable, Identifiable {
    case holdToTalk
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdToTalk:
            "Hold to Talk"
        case .toggle:
            "Toggle"
        }
    }
}

enum TextInsertionMode: String, CaseIterable, Identifiable {
    case pasteboard
    case keystrokes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteboard:
            "Pasteboard"
        case .keystrokes:
            "Keystrokes"
        }
    }
}

enum RefinementBackend: String, CaseIterable, Identifiable {
    case heuristic
    case llamaCPP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heuristic:
            "Heuristic"
        case .llamaCPP:
            "llama.cpp"
        }
    }
}

enum RefinementProfile: String, CaseIterable, Identifiable {
    case balanced
    case email
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            "Balanced"
        case .email:
            "Email"
        case .chat:
            "Chat"
        }
    }

    var instructions: String {
        switch self {
        case .balanced:
            "Make the text read naturally and clearly without changing the meaning."
        case .email:
            "Shape the text into polished, professional prose that feels ready for an email draft."
        case .chat:
            "Keep the phrasing casual and conversational while removing dictation artifacts."
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let whisperLanguageOptions: [WhisperLanguageOption] = [
        WhisperLanguageOption(code: "auto", title: "Auto Detect"),
        WhisperLanguageOption(code: "en", title: "English"),
        WhisperLanguageOption(code: "pt", title: "Portuguese"),
        WhisperLanguageOption(code: "es", title: "Spanish"),
        WhisperLanguageOption(code: "fr", title: "French"),
        WhisperLanguageOption(code: "de", title: "German"),
        WhisperLanguageOption(code: "it", title: "Italian"),
        WhisperLanguageOption(code: "nl", title: "Dutch"),
        WhisperLanguageOption(code: "ru", title: "Russian"),
        WhisperLanguageOption(code: "uk", title: "Ukrainian"),
        WhisperLanguageOption(code: "pl", title: "Polish"),
        WhisperLanguageOption(code: "tr", title: "Turkish"),
        WhisperLanguageOption(code: "ar", title: "Arabic"),
        WhisperLanguageOption(code: "hi", title: "Hindi"),
        WhisperLanguageOption(code: "ja", title: "Japanese"),
        WhisperLanguageOption(code: "ko", title: "Korean"),
        WhisperLanguageOption(code: "zh", title: "Chinese"),
    ]

    @Published var triggerMode: RecordingTriggerMode
    @Published var insertionMode: TextInsertionMode
    @Published var whisperExecutablePath: String
    @Published var whisperModelPath: String
    @Published var whisperLanguage: String
    @Published var enableRefinement: Bool
    @Published var refinementBackend: RefinementBackend
    @Published var refinementProfile: RefinementProfile
    @Published var llamaExecutablePath: String
    @Published var llamaModelPath: String

    var isWhisperConfigured: Bool {
        whisperConfigurationIssue == nil
    }

    var isLlamaConfigured: Bool {
        llamaConfigurationIssue == nil
    }

    var whisperExecutableValidation: PathValidation {
        Self.validateExecutable(path: whisperExecutablePath, displayName: "Whisper CLI", expectedName: "whisper-cli")
    }

    var whisperModelValidation: PathValidation {
        Self.validateFile(path: whisperModelPath, displayName: "Whisper model", preferredExtension: "bin")
    }

    var whisperLanguageValidation: PathValidation {
        guard whisperModelValidation.status != .invalid else {
            return PathValidation(status: .warning, message: "Select a Whisper model to validate language behavior.")
        }

        if isEnglishOnlyWhisperModel {
            if normalizedWhisperLanguage == "auto" {
                return PathValidation(status: .warning, message: "This model appears to be English-only. Auto Detect will be treated as English.")
            }

            if normalizedWhisperLanguage != "en" {
                return PathValidation(status: .invalid, message: "This model appears to be English-only. Select English.")
            }

            return PathValidation(status: .valid, message: "English matches this English-only model.")
        }

        if normalizedWhisperLanguage == "auto" {
            return PathValidation(status: .valid, message: "Auto detect is enabled for this model.")
        }

        return PathValidation(status: .valid, message: "Language is locked to \(whisperLanguageTitle(for: normalizedWhisperLanguage)).")
    }

    var llamaExecutableValidation: PathValidation {
        Self.validateExecutable(path: llamaExecutablePath, displayName: "Llama CLI", expectedName: "llama-cli")
    }

    var llamaModelValidation: PathValidation {
        Self.validateFile(path: llamaModelPath, displayName: "Llama model", preferredExtension: "gguf")
    }

    var whisperConfigurationIssue: String? {
        firstBlockingIssue(in: [
            whisperExecutableValidation,
            whisperModelValidation,
            whisperLanguageValidation,
        ])
    }

    var llamaConfigurationIssue: String? {
        firstBlockingIssue(in: [
            llamaExecutableValidation,
            llamaModelValidation,
        ])
    }

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    var normalizedWhisperLanguage: String {
        Self.normalizedWhisperLanguageCode(whisperLanguage)
    }

    var effectiveWhisperLanguage: String {
        if isEnglishOnlyWhisperModel && normalizedWhisperLanguage == "auto" {
            return "en"
        }

        return normalizedWhisperLanguage
    }

    var isEnglishOnlyWhisperModel: Bool {
        let filename = URL(fileURLWithPath: whisperModelPath).lastPathComponent.lowercased()
        return filename.contains(".en.") || filename.hasSuffix(".en.bin")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        triggerMode = RecordingTriggerMode(rawValue: defaults.string(forKey: Keys.triggerMode.rawValue) ?? "") ?? .holdToTalk
        insertionMode = TextInsertionMode(rawValue: defaults.string(forKey: Keys.insertionMode.rawValue) ?? "") ?? .pasteboard
        whisperExecutablePath = defaults.string(forKey: Keys.whisperExecutablePath.rawValue) ?? Self.defaultExecutablePath(named: "whisper-cli")
        whisperModelPath = defaults.string(forKey: Keys.whisperModelPath.rawValue) ?? ""
        whisperLanguage = Self.normalizedWhisperLanguageCode(defaults.string(forKey: Keys.whisperLanguage.rawValue))
        enableRefinement = defaults.object(forKey: Keys.enableRefinement.rawValue) as? Bool ?? true
        refinementBackend = RefinementBackend(rawValue: defaults.string(forKey: Keys.refinementBackend.rawValue) ?? "") ?? .heuristic
        refinementProfile = RefinementProfile(rawValue: defaults.string(forKey: Keys.refinementProfile.rawValue) ?? "") ?? .balanced
        llamaExecutablePath = defaults.string(forKey: Keys.llamaExecutablePath.rawValue) ?? Self.defaultExecutablePath(named: "llama-cli")
        llamaModelPath = defaults.string(forKey: Keys.llamaModelPath.rawValue) ?? ""

        bind()
    }

    private func bind() {
        $triggerMode
            .map(\.rawValue)
            .sink { [defaults] in defaults.set($0, forKey: Keys.triggerMode.rawValue) }
            .store(in: &cancellables)

        $insertionMode
            .map(\.rawValue)
            .sink { [defaults] in defaults.set($0, forKey: Keys.insertionMode.rawValue) }
            .store(in: &cancellables)

        $whisperExecutablePath
            .sink { [defaults] in defaults.set($0, forKey: Keys.whisperExecutablePath.rawValue) }
            .store(in: &cancellables)

        $whisperModelPath
            .sink { [defaults] in defaults.set($0, forKey: Keys.whisperModelPath.rawValue) }
            .store(in: &cancellables)

        $whisperLanguage
            .map(Self.normalizedWhisperLanguageCode)
            .sink { [defaults] in defaults.set($0, forKey: Keys.whisperLanguage.rawValue) }
            .store(in: &cancellables)

        $enableRefinement
            .sink { [defaults] in defaults.set($0, forKey: Keys.enableRefinement.rawValue) }
            .store(in: &cancellables)

        $refinementBackend
            .map(\.rawValue)
            .sink { [defaults] in defaults.set($0, forKey: Keys.refinementBackend.rawValue) }
            .store(in: &cancellables)

        $refinementProfile
            .map(\.rawValue)
            .sink { [defaults] in defaults.set($0, forKey: Keys.refinementProfile.rawValue) }
            .store(in: &cancellables)

        $llamaExecutablePath
            .sink { [defaults] in defaults.set($0, forKey: Keys.llamaExecutablePath.rawValue) }
            .store(in: &cancellables)

        $llamaModelPath
            .sink { [defaults] in defaults.set($0, forKey: Keys.llamaModelPath.rawValue) }
            .store(in: &cancellables)
    }

    private static func defaultExecutablePath(named name: String) -> String {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? candidates[0]
    }

    private func firstBlockingIssue(in validations: [PathValidation]) -> String? {
        validations.first(where: \.isBlocking)?.message
    }

    private static func normalizedWhisperLanguageCode(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return whisperLanguageOptions.contains(where: { $0.code == trimmed }) ? trimmed : "auto"
    }

    private func whisperLanguageTitle(for code: String) -> String {
        Self.whisperLanguageOptions.first(where: { $0.code == code })?.title ?? code
    }

    private static func validateExecutable(path: String, displayName: String, expectedName: String) -> PathValidation {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPath.isEmpty else {
            return PathValidation(status: .invalid, message: "\(displayName) path is missing.")
        }

        guard FileManager.default.fileExists(atPath: trimmedPath) else {
            return PathValidation(status: .invalid, message: "\(displayName) was not found at \(trimmedPath).")
        }

        guard FileManager.default.isExecutableFile(atPath: trimmedPath) else {
            return PathValidation(status: .invalid, message: "\(displayName) exists but is not executable.")
        }

        if URL(fileURLWithPath: trimmedPath).lastPathComponent != expectedName {
            return PathValidation(status: .warning, message: "\(displayName) is executable, but the filename does not match \(expectedName).")
        }

        return PathValidation(status: .valid, message: "\(displayName) is ready.")
    }

    private static func validateFile(path: String, displayName: String, preferredExtension: String) -> PathValidation {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPath.isEmpty else {
            return PathValidation(status: .invalid, message: "\(displayName) path is missing.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDirectory) else {
            return PathValidation(status: .invalid, message: "\(displayName) was not found at \(trimmedPath).")
        }

        guard !isDirectory.boolValue else {
            return PathValidation(status: .invalid, message: "\(displayName) points to a folder, not a file.")
        }

        if URL(fileURLWithPath: trimmedPath).pathExtension.lowercased() != preferredExtension {
            return PathValidation(status: .warning, message: "\(displayName) exists, but the file does not end in .\(preferredExtension).")
        }

        return PathValidation(status: .valid, message: "\(displayName) is ready.")
    }

    private enum Keys: String {
        case triggerMode
        case insertionMode
        case whisperExecutablePath
        case whisperModelPath
        case whisperLanguage
        case enableRefinement
        case refinementBackend
        case refinementProfile
        case llamaExecutablePath
        case llamaModelPath
    }
}
