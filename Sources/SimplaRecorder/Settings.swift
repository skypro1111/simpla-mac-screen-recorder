import AppKit
import SwiftUI

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let format = "format", codec = "codec", fps = "fps"
        static let systemAudio = "captureSystemAudio", microphone = "captureMicrophone"
        static let outputDirectory = "outputDirectory"
    }

    static let defaultOutputDirectory = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Simpla Recorder", isDirectory: true)

    @Published var format: VideoFormat { didSet { defaults.set(format.rawValue, forKey: Key.format) } }
    @Published var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }
    @Published var fps: Int { didSet { defaults.set(fps, forKey: Key.fps) } }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: Key.systemAudio) } }
    @Published var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: Key.microphone) } }
    @Published var outputDirectory: URL { didSet { defaults.set(outputDirectory.path, forKey: Key.outputDirectory) } }

    private init() {
        defaults.register(defaults: [
            Key.format: VideoFormat.mp4.rawValue,
            Key.codec: VideoCodec.h264.rawValue,
            Key.fps: 30,
            Key.systemAudio: true,
            Key.microphone: false,
        ])
        format = VideoFormat(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .mp4
        codec = VideoCodec(rawValue: defaults.string(forKey: Key.codec) ?? "") ?? .h264
        let storedFPS = defaults.integer(forKey: Key.fps)
        fps = storedFPS > 0 ? storedFPS : 30
        captureSystemAudio = defaults.bool(forKey: Key.systemAudio)
        captureMicrophone = defaults.bool(forKey: Key.microphone)
        if let path = defaults.string(forKey: Key.outputDirectory), !path.isEmpty {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputDirectory = Self.defaultOutputDirectory
        }
    }

    var recordingOptions: RecordingOptions {
        RecordingOptions(format: format, codec: codec, fps: fps,
                         captureSystemAudio: captureSystemAudio,
                         captureMicrophone: captureMicrophone,
                         outputDirectory: outputDirectory)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker("Format", selection: $settings.format) {
                Text("MP4").tag(VideoFormat.mp4)
                Text("MOV").tag(VideoFormat.mov)
            }
            Picker("Codec", selection: $settings.codec) {
                Text("H.264").tag(VideoCodec.h264)
                Text("HEVC").tag(VideoCodec.hevc)
            }
            Picker("Frame Rate", selection: $settings.fps) {
                ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            Toggle("Record microphone by default", isOn: $settings.captureMicrophone)
            Toggle("Record system audio by default", isOn: $settings.captureSystemAudio)
            LabeledContent("Save to") {
                HStack {
                    Text((settings.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.outputDirectory.path)
                    Button("Choose…", action: chooseFolder)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = settings.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectory = url
        }
    }
}
