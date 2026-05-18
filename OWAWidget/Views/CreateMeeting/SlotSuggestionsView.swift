import SwiftUI

enum SlotRanker {
    /// Один «лучший» (самый высокий score) слот из каждого дня, отсортированный по дате, до `limit` элементов.
    static func topPicks(from slots: [FreeSlot], limit: Int = 5) -> [FreeSlot] {
        let cal = AppTimeZone.calendar
        let grouped = Dictionary(grouping: slots) { cal.startOfDay(for: $0.start) }
        return grouped
            .compactMap { _, group in group.max(by: { $0.score < $1.score }) }
            .sorted { $0.start < $1.start }
            .prefix(limit)
            .map { $0 }
    }

    static func reasonKey(for slot: FreeSlot) -> String {
        switch slot.score {
        case 0.85...: return "create.meeting.suggestions.reason.early"
        case 0.55...: return "create.meeting.suggestions.reason.morning"
        case 0.25...: return "create.meeting.suggestions.reason.afternoon"
        default:      return "create.meeting.suggestions.reason.lateday"
        }
    }
}

struct SlotSuggestionsView: View {
    @EnvironmentObject private var localization: LocalizationService
    let suggestions: [FreeSlot]
    let selectedSlot: FreeSlot?
    let onSelect: (FreeSlot) -> Void

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                    Text(localization.tr("create.meeting.suggestions.title"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.3)
                }
                VStack(spacing: 4) {
                    ForEach(suggestions) { slot in
                        suggestionRow(slot)
                    }
                }
            }
        }
    }

    private func suggestionRow(_ slot: FreeSlot) -> some View {
        let isSelected = slot.id == selectedSlot?.id
        let day = Self.dayFmt.string(from: slot.start).capitalized
        let timeRange = "\(Self.timeFmt.string(from: slot.start)) – \(Self.timeFmt.string(from: slot.end))"
        let reason = localization.tr(SlotRanker.reasonKey(for: slot))

        return Button {
            onSelect(slot)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                Text(day)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(timeRange)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer()
                Text(reason)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill((isSelected ? Color.accentColor : Color(nsColor: .controlColor))
                                .opacity(isSelected ? 0.12 : 1.0))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
