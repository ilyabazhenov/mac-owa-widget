import AppKit
import SwiftUI

/// The width a legacy ("always shown") scroller takes. SwiftUI's `ScrollView` on macOS draws it
/// over the trailing edge of the content instead of insetting the content, which clipped the
/// list's times and the sidebar's counts with a mouse connected. Content pads by this much.
@MainActor
final class ScrollerStyleObserver: ObservableObject {
    @Published private(set) var trailingInset: CGFloat = ScrollerStyleObserver.currentInset()
    // Written once in init, read once in deinit.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trailingInset = ScrollerStyleObserver.currentInset() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static func currentInset() -> CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }
}

private struct ScrollerInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var scrollerInset: CGFloat {
        get { self[ScrollerInsetKey.self] }
        set { self[ScrollerInsetKey.self] = newValue }
    }
}

/// Column widths of the mail window, remembered between launches.
enum MailColumnWidths {
    static let sidebar = (key: "mailSidebarWidth", min: 160.0, ideal: 220.0, max: 380.0)
    static let list = (key: "mailListWidth", min: 280.0, ideal: 360.0, max: 620.0)
    static let agenda = (key: "mailAgendaWidth", min: 220.0, ideal: 280.0, max: 440.0)
    static let readerMin: CGFloat = 380
    /// The row atop the list, the reader and the agenda: one height, so their dividers line up.
    static let headerHeight: CGFloat = 36

    static func clamp(_ value: Double, _ spec: (key: String, min: Double, ideal: Double, max: Double)) -> CGFloat {
        guard value > 0 else { return spec.ideal }
        return CGFloat(min(max(value, spec.min), spec.max))
    }

    /// Narrowest window the three mail columns fit in (the agenda gives way first).
    static var windowMin: CGFloat { CGFloat(sidebar.min + list.min) + readerMin + 2 }

    struct Fit: Equatable {
        var sidebar: CGFloat
        var list: CGFloat
        /// `nil` when the agenda is off or does not fit.
        var agenda: CGFloat?
    }

    /// Fits the preferred widths into `total` so the reader keeps its minimum: the list and then
    /// the sidebar shrink towards their minimums, and when that is not enough the agenda hides.
    /// A window narrower than every minimum keeps the minimums (the window cannot go smaller).
    static func fit(total: CGFloat, sidebar: CGFloat, list: CGFloat, agenda: CGFloat?) -> Fit {
        let dividers: CGFloat = 2
        func squeeze(_ room: CGFloat) -> Fit? {
            var fit = Fit(sidebar: sidebar, list: list, agenda: nil)
            var excess = sidebar + list + readerMin + dividers - room
            if excess > 0 {
                let cut = min(excess, list - CGFloat(Self.list.min))
                fit.list -= cut
                excess -= cut
            }
            if excess > 0 {
                let cut = min(excess, sidebar - CGFloat(Self.sidebar.min))
                fit.sidebar -= cut
                excess -= cut
            }
            return excess > 0.5 ? nil : fit
        }
        if let agenda, var fit = squeeze(total - agenda - 1) {
            fit.agenda = agenda
            return fit
        }
        return squeeze(total) ?? Fit(sidebar: CGFloat(Self.sidebar.min), list: CGFloat(Self.list.min), agenda: nil)
    }
}

/// A one-point divider with a wider invisible handle: dragging it resizes the column on its
/// `leading` side (or the one on its trailing side with `resizesTrailing`).
struct MailColumnDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    var resizesTrailing = false
    @State private var startWidth: Double?
    /// The resize cursor is on the cursor stack: popped on leaving, and on disappearing while
    /// hovered (a column hidden under the pointer), or it would stay for good.
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside, !pushedCursor {
                            NSCursor.resizeLeftRight.push()
                            pushedCursor = true
                        } else if !inside, pushedCursor {
                            NSCursor.pop()
                            pushedCursor = false
                        }
                    }
                    .onDisappear {
                        if pushedCursor {
                            NSCursor.pop()
                            pushedCursor = false
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                let delta = resizesTrailing ? -value.translation.width : value.translation.width
                                width = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
                    .onTapGesture(count: 2) { width = 0 } // back to the default width
            }
    }
}
