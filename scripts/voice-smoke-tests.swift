import Foundation

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}

private struct DefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults

    func reset() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private struct SmokeTest {
    let name: String
    let run: @MainActor () async throws -> Void
}

@MainActor
@main
enum VoiceSmokeTests {
    static func main() async throws {
        let tests: [SmokeTest] = [
            SmokeTest(name: "Preferred languages start unset", run: testPreferredLanguagesStartUnset),
            SmokeTest(name: "Preferred language cycling rotates", run: testCyclePreferredWhisperLanguageRotates),
            SmokeTest(name: "Preferred language cycling falls back to first option", run: testCyclePreferredWhisperLanguageFallsBackToFirstConfiguredLanguage),
            SmokeTest(name: "English-only Whisper forces English", run: testCyclePreferredWhisperLanguageUsesEnglishForEnglishOnlyModel),
            SmokeTest(name: "Preferred language cycling fails when nothing is configured", run: testCyclePreferredWhisperLanguageReturnsUnavailableWithoutConfiguredPreference),
            SmokeTest(name: "Heuristic refiner removes fillers and adds punctuation", run: testHeuristicTextRefinerRemovesFillersAndAddsPunctuation),
            SmokeTest(name: "Heuristic refiner preserves sentence terminators", run: testHeuristicTextRefinerPreservesExistingSentenceTerminator),
            SmokeTest(name: "Heuristic refiner fails when only fillers remain", run: testHeuristicTextRefinerThrowsWhenOnlyFillersRemain),
            SmokeTest(name: "Llama output cleanup strips prompt wrappers and sentinels", run: testExtractRefinedTextRemovesPromptQuotesAndSentinels),
            SmokeTest(name: "Llama executable fallback prefers llama-completion", run: testRefinementExecutablePrefersLlamaCompletionWhenAvailable),
        ]

        var failures: [String] = []

        for test in tests {
            print("Running: \(test.name)")
            do {
                try await test.run()
                print("Passed: \(test.name)\n")
            } catch {
                let message = "Failed: \(test.name)\n\(error)"
                failures.append(message)
                fputs(message + "\n\n", stderr)
            }
        }

        guard failures.isEmpty else {
            throw SmokeFailure(description: "\(failures.count) smoke test(s) failed.")
        }

        print("All \(tests.count) smoke tests passed.")
    }

    private static func testPreferredLanguagesStartUnset() async throws {
        let fixture = makeDefaultsFixture(prefix: "AppSettingsDefaults")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)

        try expectEqual(settings.preferredWhisperLanguageOne, "", "Preferred Language 1 should default to not set.")
        try expectEqual(settings.preferredWhisperLanguageTwo, "", "Preferred Language 2 should default to not set.")
        try expect(settings.configuredPreferredWhisperLanguages.isEmpty, "Preferred language list should start empty.")
    }

    private static func testCyclePreferredWhisperLanguageRotates() async throws {
        let fixture = makeDefaultsFixture(prefix: "AppSettingsCycle")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)
        settings.preferredWhisperLanguageOne = "en"
        settings.preferredWhisperLanguageTwo = "pt"
        settings.whisperLanguage = "en"

        try expectEqual(
            settings.cyclePreferredWhisperLanguage(),
            .switched(title: "Portuguese"),
            "Cycling should move from English to Portuguese."
        )
        try expectEqual(settings.whisperLanguage, "pt", "Whisper language should update to Portuguese.")

        try expectEqual(
            settings.cyclePreferredWhisperLanguage(),
            .switched(title: "English"),
            "Cycling should wrap back to English."
        )
        try expectEqual(settings.whisperLanguage, "en", "Whisper language should wrap back to English.")
    }

    private static func testCyclePreferredWhisperLanguageFallsBackToFirstConfiguredLanguage() async throws {
        let fixture = makeDefaultsFixture(prefix: "AppSettingsFallback")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)
        settings.preferredWhisperLanguageOne = "en"
        settings.preferredWhisperLanguageTwo = "pt"
        settings.whisperLanguage = "auto"

        try expectEqual(
            settings.cyclePreferredWhisperLanguage(),
            .switched(title: "English"),
            "Cycling should pick the first preferred language when the active language is outside the cycle."
        )
        try expectEqual(settings.whisperLanguage, "en", "Whisper language should fall back to English.")
    }

    private static func testCyclePreferredWhisperLanguageUsesEnglishForEnglishOnlyModel() async throws {
        let fixture = makeDefaultsFixture(prefix: "AppSettingsEnglishOnly")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)
        settings.whisperModelPath = "/tmp/ggml-base.en.bin"
        settings.preferredWhisperLanguageOne = "pt"
        settings.preferredWhisperLanguageTwo = "en"
        settings.whisperLanguage = "pt"

        try expectEqual(
            settings.cyclePreferredWhisperLanguage(),
            .switched(title: "English"),
            "English-only models should only cycle to English."
        )
        try expectEqual(settings.whisperLanguage, "en", "Whisper language should switch to English for English-only models.")
    }

    private static func testCyclePreferredWhisperLanguageReturnsUnavailableWithoutConfiguredPreference() async throws {
        let fixture = makeDefaultsFixture(prefix: "AppSettingsUnavailable")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)
        let result = settings.cyclePreferredWhisperLanguage()

        guard case .unavailable(let message) = result else {
            throw SmokeFailure(description: "Cycling should fail when no preferred languages are configured.")
        }

        try expectEqual(
            message,
            "Set Preferred Language 1 or 2 before using the switch-language shortcut.",
            "Missing preferred-language guidance changed unexpectedly."
        )
    }

    private static func testHeuristicTextRefinerRemovesFillersAndAddsPunctuation() async throws {
        let fixture = makeDefaultsFixture(prefix: "HeuristicRefinerPunctuation")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)
        let refiner = HeuristicTextRefiner()
        let refined = try await refiner.refine("um hello   world", settings: settings)

        try expectEqual(refined, "Hello world.", "Heuristic refinement should remove filler words and add punctuation.")
    }

    private static func testHeuristicTextRefinerPreservesExistingSentenceTerminator() async throws {
        let fixture = makeDefaultsFixture(prefix: "HeuristicRefinerTerminator")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)
        let refiner = HeuristicTextRefiner()
        let refined = try await refiner.refine("uh hi there?", settings: settings)

        try expectEqual(refined, "Hi there?", "Existing sentence terminators should be preserved.")
    }

    private static func testHeuristicTextRefinerThrowsWhenOnlyFillersRemain() async throws {
        let fixture = makeDefaultsFixture(prefix: "HeuristicRefinerEmpty")
        defer { fixture.reset() }

        let settings = AppSettings(defaults: fixture.defaults)
        let refiner = HeuristicTextRefiner()

        do {
            _ = try await refiner.refine("um uh er", settings: settings)
            throw SmokeFailure(description: "Expected heuristic refinement to fail when only filler words remain.")
        } catch let error as DictationServiceError {
            guard case .emptyResult(let message) = error else {
                throw SmokeFailure(description: "Expected an emptyResult error, got \(error).")
            }

            try expectEqual(
                message,
                "The refinement step removed the entire transcript.",
                "Unexpected empty-result message from heuristic refiner."
            )
        }
    }

    private static func testExtractRefinedTextRemovesPromptQuotesAndSentinels() async throws {
        let prompt = LlamaCppTextRefiner.buildPrompt(rawText: "raw input", profile: .balanced)
        let output = """
        \(prompt)
        "Hello there."
        <|endoftext|>
        """

        let cleaned = LlamaCppTextRefiner.extractRefinedText(from: output, prompt: prompt)

        try expectEqual(cleaned, "Hello there.", "Llama output cleanup should strip quotes and sentinel markers.")
    }

    private static func testRefinementExecutablePrefersLlamaCompletionWhenAvailable() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let llamaCLIURL = directoryURL.appendingPathComponent("llama-cli")
        let llamaCompletionURL = directoryURL.appendingPathComponent("llama-completion")

        FileManager.default.createFile(atPath: llamaCLIURL.path, contents: Data())
        FileManager.default.createFile(atPath: llamaCompletionURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: llamaCompletionURL.path)

        try expectEqual(
            LlamaCppTextRefiner.refinementExecutable(from: llamaCLIURL.path),
            llamaCompletionURL.path,
            "llama-completion should be preferred when it exists beside llama-cli."
        )
    }
}

private func makeDefaultsFixture(prefix: String) -> DefaultsFixture {
    let suiteName = "VoiceSmokeTests.\(prefix).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("/usr/bin/true", forKey: "whisperExecutablePath")
    defaults.set("/usr/bin/true", forKey: "llamaExecutablePath")
    return DefaultsFixture(suiteName: suiteName, defaults: defaults)
}

private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw SmokeFailure(description: message)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw SmokeFailure(description: "\(message)\nExpected: \(expected)\nActual: \(actual)")
    }
}
