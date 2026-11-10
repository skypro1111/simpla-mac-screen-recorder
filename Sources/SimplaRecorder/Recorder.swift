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

/// Records the screen via SCStream sample buffers written with AVAssetWriter.
/// (SCRecordingOutput would be less code, but it makes macOS add its own stop button
/// to the menu bar next to ours.) When both audio sources are present the file has
/// two audio tracks, so a post-stop pass mixes them into one.
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    enum State: Equatable { case idle, recording(since: Date), finishing }

    @Published private(set) var state: State = .idle

    /// Called on the main actor when the stream dies on its own (e.g. window closed, user stopped sharing from the system UI). The file is finalized if possible; URL is the result if it was saved.
    var onUnexpectedStop: ((URL?, Error?) -> Void)?

    private var isStarting = false
    private var stream: SCStream?
    private var writer: StreamWriter?
    private var outputURL: URL?
    private var fileType: AVFileType = .mp4

    func start(target: CaptureTarget, options: RecordingOptions) async throws {
        guard state == .idle, !isStarting else { throw RecorderError.alreadyRunning }
        isStarting = true
        defer { isStarting = false }

        if options.captureMicrophone {
            try await Self.ensureMicrophoneAccess()
        }

        // Resolve the content filter and the capture size in points.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // Our own windows (dim overlay, preview) never belong in a recording.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        var sourceRect: CGRect?
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError.displayNotFound
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError.windowNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .area(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayNotFound
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            sourceRect = rect.standardized
        }
        let pointSize = sourceRect?.size ?? filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        // Native pixel size, scaled down (never up) to the chosen maximum height.
        var pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        if options.maxHeight > 0, pixelSize.height > CGFloat(options.maxHeight) {
            let factor = CGFloat(options.maxHeight) / pixelSize.height
            pixelSize = CGSize(width: pixelSize.width * factor, height: CGFloat(options.maxHeight))
        }
        config.width = Self.even(pixelSize.width)
        config.height = Self.even(pixelSize.height)
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

        let writer = try StreamWriter(url: url, fileType: fileType, codec: options.codec,
                                      width: config.width, height: config.height, fps: max(1, options.fps),
                                      systemAudio: options.captureSystemAudio, microphone: options.captureMicrophone)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.captureSystemAudio {
                try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            }
            if options.captureMicrophone {
                try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
            }
            self.stream = stream
            self.writer = writer
            self.outputURL = url
            self.fileType = fileType
            try await stream.startCapture()
        } catch {
            writer.cancel()
            reset()
            throw error
        }
        state = .recording(since: Date())
    }

    /// Stops and returns the final file URL.
    @discardableResult func stop() async throws -> URL {
        guard case .recording = state, let stream, let writer, let url = outputURL else {
            throw RecorderError.notRecording
        }
        state = .finishing
        defer { reset() }
        do {
            try await stream.stopCapture()
        } catch {
            // The stream may already be dead; still try to finalize whatever was written.
        }
        return try await finalize(url: url, writer: writer)
    }

    // MARK: - Private

    /// Closes the file and mixes audio tracks if needed.
    private func finalize(url: URL, writer: StreamWriter) async throws -> URL {
        try await writer.finish()
        // Mixing failure is not fatal: the original file (with separate tracks) is kept.
        try? await Self.mixAudioTracks(at: url, fileType: fileType)
        return url
    }

    private func reset() {
        stream = nil
        writer = nil
        outputURL = nil
        state = .idle
    }

    private func handleUnexpectedStop(streamID: ObjectIdentifier, error: Error) async {
        guard case .recording = state, let stream, ObjectIdentifier(stream) == streamID,
              let writer, let url = outputURL else { return }
        state = .finishing
        let savedURL = try? await finalize(url: url, writer: writer)
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

// MARK: - Sample writer

/// Receives the stream's sample buffers and writes them to the file. All state is
/// touched only on `queue` (also the stream's sample handler queue), hence @unchecked Sendable.
private final class StreamWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "Recorder.samples")

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var started = false
    private var finished = false
    /// Last appended video frame, repeated at the end so a static screen keeps its real duration.
    private var lastFrame: CMSampleBuffer?

    init(url: URL, fileType: AVFileType, codec: VideoCodec, width: Int, height: Int, fps: Int,
         systemAudio: Bool, microphone: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        self.writer = writer

        // Screen content compresses well; HEVC needs roughly 60% of the H.264 bitrate.
        let bitrate = max(2_000_000, Int(Double(width * height * fps) * (codec == .hevc ? 0.06 : 0.1)))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        self.video = video

        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            return input
        }
        audio = systemAudio ? audioInput() : nil
        self.microphone = microphone ? audioInput() : nil

        super.init()
        guard writer.startWriting() else { throw writer.error ?? RecorderError.recordingFailed(nil) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, writer.status == .writing else { return }
        switch type {
        case .screen:
            // Skip idle/blank frames that carry no image.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: status) == .complete else { return }
            if !started {
                // The file's timeline starts at the first video frame.
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                started = true
            }
            if video.isReadyForMoreMediaData, video.append(sampleBuffer) { lastFrame = sampleBuffer }
        case .audio:
            if started, let audio, audio.isReadyForMoreMediaData { audio.append(sampleBuffer) }
        case .microphone:
            if started, let microphone, microphone.isReadyForMoreMediaData { microphone.append(sampleBuffer) }
        @unknown default:
            break
        }
    }

    /// Finishes the file. Throws if nothing was captured or writing failed.
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.finished = true
                guard self.started, self.writer.status == .writing else {
                    let error = self.writer.error
                    self.writer.cancelWriting()
                    continuation.resume(throwing: error ?? RecorderError.recordingFailed("No frames were captured."))
                    return
                }
                // A static screen produces no new frames, so the video would end at the last change.
                // Repeat the last frame at the real end time to keep the full duration.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if let last = self.lastFrame, now > last.presentationTimeStamp, self.video.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                          sampleTimingArray: &timing, sampleBufferOut: &copy)
                    if let copy { self.video.append(copy) }
                }
                self.lastFrame = nil
                self.writer.endSession(atSourceTime: now)
                for input in [self.video, self.audio, self.microphone] { input?.markAsFinished() }
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: self.writer.error ?? RecorderError.recordingFailed(nil))
                    }
                }
            }
        }
    }

    /// Abandons the file (capture never started).
    func cancel() {
        queue.async {
            self.finished = true
            self.writer.cancelWriting()
        }
    }
}
