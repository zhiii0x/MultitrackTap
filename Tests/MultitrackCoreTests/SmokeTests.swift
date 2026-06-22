import XCTest
@testable import MultitrackCore

final class SmokeTests: XCTestCase {
    func test_version_isSet() {
        XCTAssertEqual(MultitrackCore.version, "0.1.0")
    }
}
