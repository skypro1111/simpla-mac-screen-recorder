import AVFoundation
import Foundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case alreadyRunning
    case notRecording
    case displayNotFound
    case windowNotFound
    case microphoneDenied
    case recordingFailed(String?)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A recording is already in progress."
        case .notRecording: return "Nothing is being recorded."
        case .displayNotFound: return "Display not found. It may have been disconnected."
        case .windowNotFound: return "Window not found. It may have been closed."
        case .microphoneDenied:
            return "No access to the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        case .recordingFailed(let reason):
            return "Failed to record the video." + (reason.map { " \($0)" } ?? "")
        }
    }
}

/// Records the screen via SCStream + SCRecordingOutput (macOS 15+), which writes
/// video, system audio and microphone into one file. When both audio sources are
/// present the file has two audio tracks, so a post-stop pass mixes them into one.
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    enum State: Equatable { case idle, recording(since: Date), finishing }

    @Published private(set) var state: State = .idle

    /// Called on the main actor when the stream dies on its own (e.g. window closed, user stopped sharing from the system UI). The file is finalized if possible; URL is the result if it was saved.
    var onUnexpectedStop: ((URL?, Error?) -> Void)?

    private var isStarting = false
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var fileType: AVFileType = .mp4

    // Completion of SCRecordingOutput (finish or failure).
    private var recordingDone = false
    private var recordingError: Error?
    private var doneContinuation: CheckedContinuation<Void, Never>?
    private var generation = 0

    func start(target: CaptureTarget, options: RecordingOptions) async throws {
        guard state == .idle, !isStarting else { throw RecorderError.alreadyRunning }
        isStarting = true
        defer { isStarting = false }

        if options.captureMicrophone {
            try await Self.ensureMicrophoneAccess()
        }

        // Resolve the content filter and the capture size in points.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        var sourceRect: CGRect?
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError.displayNotFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError.windowNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .area(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayNotFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            sourceRect = rect.standardized
        }
        let pointSize = sourceRect?.size ?? filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        config.width = Self.even(pointSize.width * scale)
        config.height = Self.even(pointSize.height * scale)
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.fps)))
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.captureMicrophone
        if options.captureMicrophone {
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        // Output file.
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = options.outputDirectory
            .appendingPathComponent("Screen Recording \(formatter.string(from: Date()))")
            .appendingPathExtension(options.format.fileExtension)
        let fileType: AVFileType = options.format == .mov ? .mov : .mp4

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = fileType
        recordingConfig.videoCodecType = options.codec == .hevc ? .hevc : .h264
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(output)

        generation += 1
        recordingDone = false
        recordingError = nil
        self.stream = stream
        self.recordingOutput = output
        self.outputURL = url
        self.fileType = fileType
        do {
            try await stream.startCapture()
        } catch {
            reset()
            throw error
        }
        state = .recording(since: Date())
    }

    /// Stops and returns the final file URL.
    @discardableResult func stop() async throws -> URL {
        guard case .recording = state, let stream, let url = outputURL else { throw RecorderError.notRecording }
        state = .finishing
        defer { reset() }
        do {
            try await stream.stopCapture()
        } catch {
            // The stream may already be dead; still try to finalize whatever was written.
        }
        return try await finalize(url: url)
    }

    // MARK: - Private

    /// Waits for SCRecordingOutput to close the file and mixes audio tracks if needed.
    private func finalize(url: URL) async throws -> URL {
        await waitForRecordingDone()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw recordingError ?? RecorderError.recordingFailed(nil)
        }
        // Mixing failure is not fatal: the original file (with separate tracks) is kept.
        try? await Self.mixAudioTracks(at: url, fileType: fileType)
        return url
    }

    private func waitForRecordingDone() async {
        if recordingDone { return }
        // Safety net in case the delegate never reports completion.
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.generation == current else { return }
            self.markRecordingDone(error: nil)
        }
        await withCheckedContinuation { doneContinuation = $0 }
    }

    private func recordingOutputDone(_ outputID: ObjectIdentifier, error: Error?) {
        guard let recordingOutput, ObjectIdentifier(recordingOutput) == outputID else { return }
        markRecordingDone(error: error)
    }

    private func markRecordingDone(error: Error?) {
        guard !recordingDone else { return }
        recordingDone = true
        recordingError = error
        doneContinuation?.resume()
        doneContinuation = nil
    }

    private func reset() {
        stream = nil
        recordingOutput = nil
        outputURL = nil
        state = .idle
    }

    private func handleUnexpectedStop(streamID: ObjectIdentifier, error: Error) async {
        guard case .recording = state, let stream, ObjectIdentifier(stream) == streamID,
              let url = outputURL else { return }
        state = .finishing
        let savedURL = try? await finalize(url: url)
        reset()
        onUnexpectedStop?(savedURL, error)
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }

    private static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default: break
        }
        throw RecorderError.microphoneDenied
    }

    /// If the file has more than one audio track, rewrites it with video passed
    /// through and all audio tracks mixed into a single AAC track.
    nonisolated private static func mixAudioTracks(at url: URL, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".mix-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: fileType)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []

        if let video = videoTracks.first {
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            let hint = try await video.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            input.transform = try await video.load(.preferredTransform)
            reader.add(output)
            writer.add(input)
            pairs.append((output, input))
        }

        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        reader.add(mixOutput)
        writer.add(audioInput)
        pairs.append((mixOutput, audioInput))

        guard writer.startWriting() else { throw writer.error ?? RecorderError.recordingFailed(nil) }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? RecorderError.recordingFailed(nil)
        }
        writer.startSession(atSourceTime: .zero)

        // Pump every reader output into its writer input concurrently (the writer
        // interleaves tracks, so feeding them one after another could stall).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, (output, input)) in pairs.enumerated() {
                group.enter()
                let pump = MixPump(output: output, input: input, group: group)
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "Recorder.mix.\(index)")) { pump.pump() }
            }
            group.notify(queue: .global()) { continuation.resume() }
        }

        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? writer.error ?? RecorderError.recordingFailed(nil)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecorderError.recordingFailed(nil) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}

/// Copies samples from one reader output to one writer input. Only touched on
/// the input's serial request queue, hence @unchecked Sendable.
private final class MixPump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let group: DispatchGroup
    private var finished = false

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, group: DispatchGroup) {
        self.output = output
        self.input = input
        self.group = group
    }

    func pump() {
        guard !finished else { return }
        while input.isReadyForMoreMediaData {
            if let buffer = output.copyNextSampleBuffer(), input.append(buffer) { continue }
            finished = true
            input.markAsFinished()
            group.leave()
            return
        }
    }
}

// MARK: - SCStreamDelegate

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor in
            await self.handleUnexpectedStop(streamID: streamID, error: error)
        }
    }
}

// MARK: - SCRecordingOutputDelegate

extension Recorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let outputID = ObjectIdentifier(recordingOutput)
        Task { @MainActor in self.recordingOutputDone(outputID, error: error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let outputID = ObjectIdentifier(recordingOutput)
        Task { @MainActor in self.recordingOutputDone(outputID, error: nil) }
    }
}
