// swift-tools-version: 6.0
import PackageDescription

// Multitrack Tap — the macOS app.
//
// A SwiftUI `App` packaged as an SPM executable and run from a `.app` bundle
// (assembled by make-app.sh). The bundle gives the binary a stable identity so
// macOS TCC can attribute the audio-capture (kTCCServiceAudioCapture) grant,
// which Core Audio process taps require.
//
// The audio engine (HostTime / MicrophoneTap / CoreAudioProcessTap /
// AudioProcessList) lives under Sources/MultitrackTap/Audio. The
// platform-agnostic recording core stays in the parent `MultitrackCore` package
// (consumed as a path dependency).
let package = Package(
    name: "MultitrackTap",
    // Core Audio process-tap APIs (AudioHardwareCreateProcessTap,
    // CATapDescription, …) require macOS 14.2+, so the SwiftPM platform floor
    // must be at least 14.2 for them to be available unconditionally. We use
    // 14.4 (the project's chosen min OS); Info.plist LSMinimumSystemVersion
    // also pins the runtime deployment floor to 14.4.
    platforms: [.macOS("14.4")],
    dependencies: [
        // Parent package at the repo root.
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "MultitrackTap",
            dependencies: [
                // SwiftPM derives the dependency's *package identity* from the
                // directory name of the path dependency (here: "opensour"), NOT
                // from the `name:` field in the parent Package.swift. The
                // product is still "MultitrackCore"; only the `package:`
                // identity differs.
                .product(name: "MultitrackCore", package: "opensour"),
            ]
        ),
        // Unit tests for the app layer. `@testable import MultitrackTap` reaches
        // the executable target's `internal` types (e.g. ResamplingTap).
        .testTarget(
            name: "MultitrackTapTests",
            dependencies: [
                "MultitrackTap",
                .product(name: "MultitrackCore", package: "opensour"),
            ]
        ),
    ]
)
