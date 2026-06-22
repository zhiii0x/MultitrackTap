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
        // Parent package (MultitrackCore) at the repo root. Pin the dependency
        // NAME explicitly so the package identity is stable regardless of the
        // checkout folder: a plain `.package(path: "..")` derives the identity
        // from the parent folder's name, which breaks every clone whose folder
        // isn't named the maintainer's (GitHub checks out to ".../MultitrackTap";
        // `git clone` makes a "MultitrackTap" folder — neither is "opensour").
        .package(name: "MultitrackCore", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "MultitrackTap",
            dependencies: [
                .product(name: "MultitrackCore", package: "MultitrackCore"),
            ]
        ),
        // Unit tests for the app layer. `@testable import MultitrackTap` reaches
        // the executable target's `internal` types (e.g. ResamplingTap).
        .testTarget(
            name: "MultitrackTapTests",
            dependencies: [
                "MultitrackTap",
                .product(name: "MultitrackCore", package: "MultitrackCore"),
            ]
        ),
    ]
)
