import XCTest
@testable import MultitrackTap

/// Tests `OnboardingModel`: a fresh launch presents onboarding, completing
/// persists + dismisses (a fresh model over the same store stays dismissed),
/// and replay re-shows without clearing the persisted "seen" flag.
@MainActor
final class OnboardingModelTests: XCTestCase {

    // `nonisolated(unsafe)` so the nonisolated XCTest setUp/tearDown can set and
    // clean these while the class is @MainActor. Safe: written once in setUp and
    // tests run serially. (Swift 6.0.x rejects accessing a main-actor property
    // from the nonisolated setUp; 6.2 allowed it.)
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    func testFreshLaunchPresentsOnboarding() {
        let model = OnboardingModel(defaults: defaults)
        XCTAssertTrue(model.isPresented)
    }

    func testCompletePersistsAndDismisses() {
        let model = OnboardingModel(defaults: defaults)
        model.complete()
        XCTAssertFalse(model.isPresented)

        // A brand-new model over the same store reads the persisted flag and
        // stays dismissed — this also exercises init reading an existing `true`.
        let reloaded = OnboardingModel(defaults: defaults)
        XCTAssertFalse(reloaded.isPresented)
    }

    func testReplayReshowsWithoutClearingFlag() {
        let model = OnboardingModel(defaults: defaults)
        model.complete()
        model.replay()
        XCTAssertTrue(model.isPresented)

        // Completing the replayed run dismisses it again.
        model.complete()
        XCTAssertFalse(model.isPresented)

        // Flag is still set: a fresh model is dismissed.
        let reloaded = OnboardingModel(defaults: defaults)
        XCTAssertFalse(reloaded.isPresented)
    }
}
