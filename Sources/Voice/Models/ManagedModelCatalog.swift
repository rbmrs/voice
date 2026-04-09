import Foundation

enum ManagedModelEngine: String, CaseIterable, Identifiable {
    case whisper
    case llama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:
            "Whisper"
        case .llama:
            "Refinement"
        }
    }

    var directoryName: String {
        switch self {
        case .whisper:
            "Whisper"
        case .llama:
            "Llama"
        }
    }
}

struct ManagedModelDescriptor: Identifiable, Hashable {
    let id: String
    let engine: ManagedModelEngine
    let title: String
    let fileName: String
    let sourceURL: URL
    let sizeBytes: Int64
    let languageSummary: String
    let speedSummary: String
    let qualitySummary: String
    let recommendedUse: String
    let notes: String?

    var sizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: sizeBytes)
    }

    var isEnglishOnlyWhisperModel: Bool {
        fileName.contains(".en.")
    }
}

enum ManagedModelCatalog {
    static let whisperModels: [ManagedModelDescriptor] = [
        ManagedModelDescriptor(
            id: "whisper-tiny-en",
            engine: .whisper,
            title: "Whisper Tiny English",
            fileName: "ggml-tiny.en.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")!,
            sizeBytes: 77_704_715,
            languageSummary: "English only",
            speedSummary: "Fastest",
            qualitySummary: "Lowest",
            recommendedUse: "Best for quick testing and very low-latency English dictation.",
            notes: "Use this when startup speed matters more than transcript quality."
        ),
        ManagedModelDescriptor(
            id: "whisper-base-en",
            engine: .whisper,
            title: "Whisper Base English",
            fileName: "ggml-base.en.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
            sizeBytes: 147_964_211,
            languageSummary: "English only",
            speedSummary: "Very fast",
            qualitySummary: "Low-medium",
            recommendedUse: "Good lightweight default for English dictation on smaller Macs.",
            notes: "This is a strong first download if you want a compact offline setup."
        ),
        ManagedModelDescriptor(
            id: "whisper-small-en",
            engine: .whisper,
            title: "Whisper Small English",
            fileName: "ggml-small.en.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
            sizeBytes: 487_614_201,
            languageSummary: "English only",
            speedSummary: "Fast",
            qualitySummary: "Good",
            recommendedUse: "Best overall balance for English-only daily dictation.",
            notes: "This is the most practical quality-per-gigabyte Whisper pick for English."
        ),
        ManagedModelDescriptor(
            id: "whisper-medium-en",
            engine: .whisper,
            title: "Whisper Medium English",
            fileName: "ggml-medium.en.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin")!,
            sizeBytes: 1_533_774_781,
            languageSummary: "English only",
            speedSummary: "Moderate",
            qualitySummary: "Very good",
            recommendedUse: "Quality-first English dictation when you can spend more RAM and disk.",
            notes: "This is a good premium English option before stepping up to large multilingual models."
        ),
        ManagedModelDescriptor(
            id: "whisper-base-multilingual",
            engine: .whisper,
            title: "Whisper Base Multilingual",
            fileName: "ggml-base.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            sizeBytes: 147_951_465,
            languageSummary: "99 languages",
            speedSummary: "Very fast",
            qualitySummary: "Low-medium",
            recommendedUse: "Compact multilingual starter model for basic mixed-language dictation.",
            notes: "Choose this over the English-only build if you frequently switch languages."
        ),
        ManagedModelDescriptor(
            id: "whisper-small-multilingual",
            engine: .whisper,
            title: "Whisper Small Multilingual",
            fileName: "ggml-small.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            sizeBytes: 487_601_967,
            languageSummary: "99 languages",
            speedSummary: "Fast",
            qualitySummary: "Good",
            recommendedUse: "Best balanced multilingual model for everyday dictation.",
            notes: "This is the best first multilingual download for most users."
        ),
        ManagedModelDescriptor(
            id: "whisper-large-v3-turbo",
            engine: .whisper,
            title: "Whisper Large v3 Turbo",
            fileName: "ggml-large-v3-turbo.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            sizeBytes: 1_624_555_275,
            languageSummary: "99 languages",
            speedSummary: "Fast for its class",
            qualitySummary: "Near-best",
            recommendedUse: "Best premium multilingual default when you want speed and strong accuracy.",
            notes: "This is the strongest all-around Whisper choice in the current curated list."
        ),
        ManagedModelDescriptor(
            id: "whisper-large-v3",
            engine: .whisper,
            title: "Whisper Large v3",
            fileName: "ggml-large-v3.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
            sizeBytes: 3_095_033_483,
            languageSummary: "99 languages",
            speedSummary: "Slowest",
            qualitySummary: "Best",
            recommendedUse: "Maximum transcription quality for users who do not mind a heavy local model.",
            notes: "Pick this when transcript quality is more important than download size or latency."
        ),
    ]

    static let refinementModels: [ManagedModelDescriptor] = [
        ManagedModelDescriptor(
            id: "phi-3-mini-q4",
            engine: .llama,
            title: "Phi-3 Mini 4K Instruct Q4",
            fileName: "Phi-3-mini-4k-instruct-q4.gguf",
            sourceURL: URL(string: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf")!,
            sizeBytes: 2_390_375_424,
            languageSummary: "English",
            speedSummary: "Fast for an LLM",
            qualitySummary: "Good",
            recommendedUse: "Best first refinement model for local cleanup with manageable size.",
            notes: "This is the most sensible one-click refinement download for the current app."
        ),
        ManagedModelDescriptor(
            id: "phi-3-mini-fp16",
            engine: .llama,
            title: "Phi-3 Mini 4K Instruct FP16",
            fileName: "Phi-3-mini-4k-instruct-fp16.gguf",
            sourceURL: URL(string: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-fp16.gguf")!,
            sizeBytes: 7_644_807_168,
            languageSummary: "English",
            speedSummary: "Heavy",
            qualitySummary: "Higher ceiling",
            recommendedUse: "Advanced refinement option if you want the largest official Phi-3 GGUF build.",
            notes: "This version is much larger and should be treated as an opt-in quality upgrade."
        ),
    ]
    static func models(for engine: ManagedModelEngine) -> [ManagedModelDescriptor] {
        switch engine {
        case .whisper:
            whisperModels
        case .llama:
            refinementModels
        }
    }
}
