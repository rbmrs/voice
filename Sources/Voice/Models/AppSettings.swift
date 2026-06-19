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

enum PreferredWhisperLanguageCycleResult: Equatable {
    case switched(title: String)
    case unavailable(String)
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

// `RefinementProfile` is generated from Resources/refinement-contract.json
// into Sources/Voice/Generated/RefinementContract.swift — the shared
// refinement contract both this app and tools/voice-cli/voice.py derive from.

@MainActor
final class AppSettings: ObservableObject {
    private static let unsetPreferredWhisperLanguageCode = ""

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

    static let preferredWhisperLanguageOptions: [WhisperLanguageOption] = [
        WhisperLanguageOption(code: AppSettings.unsetPreferredWhisperLanguageCode, title: "Not Set"),
    ] + whisperLanguageOptions.filter { $0.code != "auto" }

    @Published var triggerMode: RecordingTriggerMode
    @Published var insertionMode: TextInsertionMode
    @Published var whisperExecutablePath: String
    @Published var whisperModelPath: String
    @Published var whisperLanguage: String
    @Published var preferredWhisperLanguageOne: String
    @Published var preferredWhisperLanguageTwo: String
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

    var configuredPreferredWhisperLanguages: [String] {
        Self.uniqueLanguageCodes([
            Self.normalizedPreferredWhisperLanguageCode(preferredWhisperLanguageOne),
            Self.normalizedPreferredWhisperLanguageCode(preferredWhisperLanguageTwo),
        ])
        .filter { !$0.isEmpty }
    }

    var isEnglishOnlyWhisperModel: Bool {
        let filename = URL(fileURLWithPath: whisperModelPath).lastPathComponent.lowercased()
        return filename.contains(".en.") || filename.hasSuffix(".en.bin")
    }

    func cyclePreferredWhisperLanguage() -> PreferredWhisperLanguageCycleResult {
        let cycleableLanguages: [String]
        if isEnglishOnlyWhisperModel {
            cycleableLanguages = configuredPreferredWhisperLanguages.filter { $0 == "en" }
        } else {
            cycleableLanguages = configuredPreferredWhisperLanguages
        }

        guard !cycleableLanguages.isEmpty else {
            return .unavailable(preferredWhisperLanguageCycleUnavailableMessage)
        }

        let currentLanguage = effectiveWhisperLanguage
        let nextLanguage: String

        if let currentIndex = cycleableLanguages.firstIndex(of: currentLanguage) {
            nextLanguage = cycleableLanguages[(currentIndex + 1) % cycleableLanguages.count]
        } else {
            nextLanguage = cycleableLanguages[0]
        }

        whisperLanguage = nextLanguage
        return .switched(title: whisperLanguageTitle(for: nextLanguage))
    }

    @discardableResult
    func resolveWhisperExecutable() -> Bool {
        guard let path = Self.detectedExecutablePath(named: "whisper-cli") else {
            return false
        }

        whisperExecutablePath = path
        return true
    }

    @discardableResult
    func resolveLlamaExecutable() -> Bool {
        guard let path = Self.detectedExecutablePath(named: "llama-cli") else {
            return false
        }

        llamaExecutablePath = path
        return true
    }

    /// Re-runs discovery for any tool whose stored path no longer validates.
    /// Call on launch so brew upgrades / fresh Cask installs Just Work without a Settings trip.
    func autoHealToolPaths() {
        if whisperExecutableValidation.status == .invalid {
            resolveWhisperExecutable()
        }
        if llamaExecutableValidation.status == .invalid {
            resolveLlamaExecutable()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        triggerMode = RecordingTriggerMode(rawValue: defaults.string(forKey: Keys.triggerMode.rawValue) ?? "") ?? .holdToTalk
        insertionMode = TextInsertionMode(rawValue: defaults.string(forKey: Keys.insertionMode.rawValue) ?? "") ?? .pasteboard
        whisperExecutablePath = defaults.string(forKey: Keys.whisperExecutablePath.rawValue) ?? Self.defaultExecutablePath(named: "whisper-cli")
        whisperModelPath = defaults.string(forKey: Keys.whisperModelPath.rawValue) ?? ""
        whisperLanguage = Self.normalizedWhisperLanguageCode(defaults.string(forKey: Keys.whisperLanguage.rawValue))
        preferredWhisperLanguageOne = Self.normalizedPreferredWhisperLanguageCode(defaults.string(forKey: Keys.preferredWhisperLanguageOne.rawValue))
        preferredWhisperLanguageTwo = Self.normalizedPreferredWhisperLanguageCode(defaults.string(forKey: Keys.preferredWhisperLanguageTwo.rawValue))
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

        $preferredWhisperLanguageOne
            .map(Self.normalizedPreferredWhisperLanguageCode)
            .sink { [defaults] in defaults.set($0, forKey: Keys.preferredWhisperLanguageOne.rawValue) }
            .store(in: &cancellables)

        $preferredWhisperLanguageTwo
            .map(Self.normalizedPreferredWhisperLanguageCode)
            .sink { [defaults] in defaults.set($0, forKey: Keys.preferredWhisperLanguageTwo.rawValue) }
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
        detectedExecutablePath(named: name) ?? ToolDiscovery.executableSearchCandidates(named: name).first ?? name
    }

    private static func detectedExecutablePath(named name: String) -> String? {
        ToolDiscovery.findExecutable(named: name)
    }

    private func firstBlockingIssue(in validations: [PathValidation]) -> String? {
        validations.first(where: \.isBlocking)?.message
    }

    private static func normalizedWhisperLanguageCode(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return whisperLanguageOptions.contains(where: { $0.code == trimmed }) ? trimmed : "auto"
    }

    private static func normalizedPreferredWhisperLanguageCode(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return preferredWhisperLanguageOptions.contains(where: { $0.code == trimmed }) ? trimmed : unsetPreferredWhisperLanguageCode
    }

    private static func uniqueLanguageCodes(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, value in
            guard !result.contains(value) else { return }
            result.append(value)
        }
    }

    private func whisperLanguageTitle(for code: String) -> String {
        Self.whisperLanguageOptions.first(where: { $0.code == code })?.title ?? code
    }

    private var preferredWhisperLanguageCycleUnavailableMessage: String {
        if configuredPreferredWhisperLanguages.isEmpty {
            return "Set Preferred Language 1 or 2 before using the switch-language shortcut."
        }

        if isEnglishOnlyWhisperModel {
            return "This Whisper model appears to be English-only. Set a preferred language to English before using the switch-language shortcut."
        }

        return "No preferred languages are available for switching."
    }

    private static func validateExecutable(path: String, displayName: String, expectedName: String) -> PathValidation {
        let trimmedPath = normalizedPath(path)

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
        let trimmedPath = normalizedPath(path)

        guard !trimmedPath.isEmpty else {
            return PathValidation(status: .invalid, message: "No \(displayName) selected. Open Settings to download or choose one.")
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

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).expandingTildeInPath
    }

    private enum Keys: String {
        case triggerMode
        case insertionMode
        case whisperExecutablePath
        case whisperModelPath
        case whisperLanguage
        case preferredWhisperLanguageOne
        case preferredWhisperLanguageTwo
        case enableRefinement
        case refinementBackend
        case refinementProfile
        case llamaExecutablePath
        case llamaModelPath
    }
}
