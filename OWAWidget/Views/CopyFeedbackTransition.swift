import SwiftUI

extension View {
    /// The copy icon turns into a tick in place (and back) instead of jumping to it. On macOS 13,
    /// which has no symbol transitions, the swap stays instant as before.
    @ViewBuilder
    func copyFeedbackTransition(value: Bool) -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.2), value: value)
        } else {
            self
        }
    }
}
