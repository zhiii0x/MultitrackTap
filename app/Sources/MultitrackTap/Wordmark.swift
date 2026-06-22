import SwiftUI

/// The **Multitrack Tap** wordmark, drawn in code (not a baked image) so it
/// always matches the live `Theme` palette, stays crisp at any size, and adapts
/// to light/dark automatically.
///
/// Brand twist: the tittle (the dot) over the "i" in "Mult*i*track" is replaced
/// by the reserved record red. The word is rendered with a dotless "i"
/// (U+0131) so the red dot is the *only* dot over that letter.
struct Wordmark: View {
    /// Point size of the wordmark text. The red dot and its position scale from
    /// this, so the lockup stays proportional at any size.
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Mult")
            dottedI
            Text("track Tap")
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .foregroundStyle(Theme.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Multitrack Tap")
    }

    /// A dotless "i" with the record-red dot floating where the tittle would be.
    /// The dot is an `overlay`, so it never affects the wordmark's layout width.
    private var dottedI: some View {
        Text("\u{0131}") // U+0131 LATIN SMALL LETTER DOTLESS I
            .overlay(alignment: .top) {
                Circle()
                    .fill(Theme.record)
                    .frame(width: size * 0.16, height: size * 0.16)
                    // Drop the dot from the text-box top down to just above the
                    // x-height stem. Tuned for SF Rounded bold — a small nudge
                    // here is the only knob if it ever sits high/low.
                    .offset(y: size * 0.20)
            }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 28) {
        Wordmark(size: 44)
        Wordmark(size: 28)
        Wordmark(size: 18)
    }
    .padding(40)
}
