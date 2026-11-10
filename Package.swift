// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimplaRecorder",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "SimplaRecorder",
            path: "Sources/SimplaRecorder"
        )
    ]
)
