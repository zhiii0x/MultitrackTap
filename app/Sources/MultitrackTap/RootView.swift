import SwiftUI

/// The main window's root: shows `OnboardingView` on first launch (until the
/// `OnboardingModel` is completed), otherwise the normal `RecordView`. Cross-fades
/// between them with the app's signature easing.
struct RootView: View {
    @Environment(OnboardingModel.self) private var onboarding

    var body: some View {
        Group {
            if onboarding.isPresented {
                OnboardingView().transition(.opacity)
            } else {
                RecordView().transition(.opacity)
            }
        }
        .animation(Theme.transition(), value: onboarding.isPresented)
    }
}
