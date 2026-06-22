import XCTest
@testable import MultitrackCore

final class RecordingExportTests: XCTestCase {
    func test_buildsReaperStemsFromResult() {
        let result = RecordingResult(stems: [
            RecordedStem(source: Source(id: "mic", name: "Me", kind: .microphone),
                         url: URL(fileURLWithPath: "/tmp/Me.wav"), frameCount: 96000),
            RecordedStem(source: Source(id: "app", name: "Zoom", kind: .app),
                         url: URL(fileURLWithPath: "/tmp/Zoom.wav"), frameCount: 96000),
        ])
        let stems = RecordingExport.reaperStems(from: result, sampleRate: 48000)
        XCTAssertEqual(stems, [
            ReaperStem(name: "Me", fileName: "Me.wav", lengthSeconds: 2.0),
            ReaperStem(name: "Zoom", fileName: "Zoom.wav", lengthSeconds: 2.0),
        ])
    }
}
