// Shared contract between the app's modules. Keep this file small.
import CoreGraphics
import Foundation

enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
}

/// What to record.
enum CaptureTarget {
    /// A whole display.
    case display(CGDirectDisplayID)
    /// A single window (CGWindowID == SCWindow.windowID).
    case window(CGWindowID)
    /// Part of a display. `rect` is in points, relative to that display's
    /// top-left corner (the coordinate space of SCStreamConfiguration.sourceRect).
    case area(displayID: CGDirectDisplayID, rect: CGRect)
}

struct RecordingOptions {
    var format: VideoFormat
    var codec: VideoCodec
    var fps: Int
    /// Maximum video height in pixels (e.g. 1080); larger captures are scaled down
    /// proportionally. 0 keeps the native resolution.
    var maxHeight: Int
    var captureSystemAudio: Bool
    var captureMicrophone: Bool
    var outputDirectory: URL
}

/// Result of the capture picker: what to record and with which audio sources.
struct CaptureChoice {
    var target: CaptureTarget
    var microphone: Bool
    var systemAudio: Bool
}
