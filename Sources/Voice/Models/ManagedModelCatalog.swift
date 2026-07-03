import Foundation

enum ManagedModelEngine: String, CaseIterable, Identifiable {
    case whisper
    case llama
    case vad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:
            "Whisper"
        case .llama:
            "Refinement"
        case .vad:
            "Voice Activity Detection"
        }
    }

    var directoryName: String {
        switch self {
        case .whisper:
            "Whisper"
        case .llama:
            "Llama"
        case .vad:
            "VAD"
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
    // Ratings drive the 1...10 gauges in ManagedModelCard. nil falls back to the text badge
    // (e.g. VAD, whose "Negligible overhead" / "Trims silence" aren't on a speed/accuracy scale).
    var speedRating: Int? = nil
    var qualityRating: Int? = nil

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
            notes: "Use this when startup speed matters more than transcript quality.",
            speedRating: 10,
            qualityRating: 2
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
            notes: "This is a strong first download if you want a compact offline setup.",
            speedRating: 8,
            qualityRating: 4
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
            notes: "This is the most practical quality-per-gigabyte Whisper pick for English.",
            speedRating: 6,
            qualityRating: 6
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
            notes: "This is a good premium English option before stepping up to large multilingual models.",
            speedRating: 4,
            qualityRating: 7
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
            notes: "Choose this over the English-only build if you frequently switch languages.",
            speedRating: 8,
            qualityRating: 4
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
            notes: "This is the best first multilingual download for most users.",
            speedRating: 6,
            qualityRating: 6
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
            notes: "This is the strongest all-around Whisper choice in the current curated list.",
            speedRating: 5,
            qualityRating: 9
        ),
        ManagedModelDescriptor(
            id: "whisper-large-v3-turbo-q8_0",
            engine: .whisper,
            title: "Whisper Large v3 Turbo (Q8_0)",
            fileName: "ggml-large-v3-turbo-q8_0.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")!,
            sizeBytes: 874_000_000,
            languageSummary: "99 languages",
            speedSummary: "Faster than full Turbo",
            qualitySummary: "Near-best",
            recommendedUse: "Best premium multilingual default: nearly identical accuracy to Turbo at about half the size and RAM.",
            notes: "Quantized build of Large v3 Turbo with near-lossless quality. Recommended over the full Turbo for most users.",
            speedRating: 6,
            qualityRating: 9
        ),
        ManagedModelDescriptor(
            id: "whisper-large-v3-turbo-q5_0",
            engine: .whisper,
            title: "Whisper Large v3 Turbo (Q5_0)",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            sourceURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
            sizeBytes: 574_000_000,
            languageSummary: "99 languages",
            speedSummary: "Fastest large-class",
            qualitySummary: "Very good",
            recommendedUse: "Smallest premium multilingual option; strongest for English on disk-constrained Macs.",
            notes: "More aggressive quantization than Q8_0. English stays strong; low-resource languages degrade slightly more.",
            speedRating: 7,
            qualityRating: 7
        ),
        ManagedModelDescriptor(
            id: "whisper-distil-large-v3.5-en",
            engine: .whisper,
            title: "Distil-Whisper Large v3.5 (English)",
            fileName: "ggml-distil-large-v3.5.en.bin",
            sourceURL: URL(string: "https://huggingface.co/distil-whisper/distil-large-v3.5-ggml/resolve/main/ggml-model.bin")!,
            sizeBytes: 1_520_000_000,
            languageSummary: "English only",
            speedSummary: "~1.5x faster than Turbo",
            qualitySummary: "Near-best (English)",
            recommendedUse: "Fastest high-accuracy English-only dictation; matches or beats Turbo on short clips.",
            notes: "Distilled Whisper from a separate Hugging Face repo. English only; language locks to English automatically.",
            speedRating: 7,
            qualityRating: 9
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
            notes: "Pick this when transcript quality is more important than download size or latency.",
            speedRating: 2,
            qualityRating: 10
        ),
    ]

    static let refinementModels: [ManagedModelDescriptor] = [
        ManagedModelDescriptor(
            id: "gemma-3-4b-it-q4",
            engine: .llama,
            title: "Gemma 3 4B Instruct Q4",
            fileName: "gemma-3-4b-it-Q4_K_M.gguf",
            sourceURL: URL(string: "https://huggingface.co/lmstudio-community/gemma-3-4B-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!,
            sizeBytes: 2_489_757_856,
            languageSummary: "Multilingual",
            speedSummary: "Fast for an LLM",
            qualitySummary: "Very good",
            recommendedUse: "Recommended refinement model: follows the cleanup instructions closely and rarely adds stray commentary.",
            notes: "Google Gemma 3 4B instruct. Strong instruction-following makes for cleaner dictation with fewer artifacts than Phi-3.",
            speedRating: 6,
            qualityRating: 8
        ),
        ManagedModelDescriptor(
            id: "qwen3-4b-instruct-2507-q4",
            engine: .llama,
            title: "Qwen3 4B Instruct Q4",
            fileName: "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            sourceURL: URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            sizeBytes: 2_497_280_736,
            languageSummary: "Multilingual",
            speedSummary: "Fast for an LLM",
            qualitySummary: "Very good",
            recommendedUse: "Strong Apache-2.0 alternative to Gemma with excellent text quality across languages.",
            notes: "Alibaba Qwen3 4B Instruct (2507, non-thinking build). Clean, direct output that suits the refinement pass.",
            speedRating: 6,
            qualityRating: 8
        ),
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
            notes: "This is the most sensible one-click refinement download for the current app.",
            speedRating: 6,
            qualityRating: 6
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
            notes: "This version is much larger and should be treated as an opt-in quality upgrade.",
            speedRating: 2,
            qualityRating: 8
        ),
    ]
    static let vadModels: [ManagedModelDescriptor] = [
        ManagedModelDescriptor(
            id: "vad-silero-v5",
            engine: .vad,
            title: "Silero VAD v5",
            fileName: "ggml-silero-v5.1.2.bin",
            sourceURL: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
            sizeBytes: 2_217_000,
            languageSummary: "Language-agnostic",
            speedSummary: "Negligible overhead",
            qualitySummary: "Trims silence",
            recommendedUse: "Download once, then enable VAD to skip silence and reduce hallucinations on quiet clips.",
            notes: "Tiny Silero voice-activity model used by whisper.cpp's --vad mode. Works with any Whisper model."
        ),
    ]

    static func models(for engine: ManagedModelEngine) -> [ManagedModelDescriptor] {
        switch engine {
        case .whisper:
            whisperModels
        case .llama:
            refinementModels
        case .vad:
            vadModels
        }
    }
}
