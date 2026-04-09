import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError {
    case alreadyRecording
    case failedToStart
    case notRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Recording is already in progress."
        case .failedToStart:
            "The microphone recorder could not start."
        case .notRecording:
            "There is no active recording to stop."
        }
    }
}

@MainActor
final class AudioCaptureService: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentRecordingURL: URL?

    func startRecording() throws -> URL {
        guard recorder == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw AudioCaptureError.failedToStart
        }

        self.recorder = recorder
        currentRecordingURL = url
        return url
    }

    func stopRecording() throws -> URL {
        guard let recorder, let currentRecordingURL else {
            throw AudioCaptureError.notRecording
        }

        recorder.stop()
        self.recorder = nil
        self.currentRecordingURL = nil
        return currentRecordingURL
    }
}
