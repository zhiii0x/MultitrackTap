import Foundation
import Observation

/// Tracks whether the first-launch onboarding has been completed, and whether it
/// is currently on screen.
///
/// Persists a single Bool to `UserDefaults` so onboarding shows exactly once.
/// The store is injectable (default `.standard`) so tests run against an isolated
/// suite — mirroring how `RecordingHistoryStore` takes an overridable directory.
@MainActor
@Observable
final class OnboardingModel {
    /// Drives the full-window takeover: true → show `OnboardingView`.
    private(set) var isPresented: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let completedKey = "hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPresented = !defaults.bool(forKey: completedKey)
    }

    /// User finished or skipped — persist the "seen" flag and dismiss. Persisting
    /// here (before any relaunch the caller may trigger) ensures the completed
    /// state survives a restart.
    func complete() {
        defaults.set(true, forKey: completedKey)
        isPresented = false
    }

    /// Re-show onboarding from the menu, WITHOUT clearing the completed flag.
    func replay() {
        isPresented = true
    }
}
