import SwiftUI

struct SlotListView: View {
    let slots: [FreeSlot]
    @Binding var selectedSlotID: UUID?

    private static let dayHeaderFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = AppTimeZone.zone
        return f
    }()

    private var grouped: [(day: Date, header: String, slots: [FreeSlot])] {
        let cal = AppTimeZone.calendar
        let dict = Dictionary(grouping: slots) { cal.startOfDay(for: $0.start) }
        return dict
            .sorted { $0.key < $1.key }
            .map { day, list in
                let header = Self.dayHeaderFmt.string(from: day).capitalized
                let sorted = list.sorted { $0.start < $1.start }
                return (day: day, header: header, slots: sorted)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(grouped, id: \.day) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(group.header)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(height: 1)
                    }
                    VStack(spacing: 4) {
                        ForEach(group.slots) { slot in
                            slotRow(slot)
                        }
                    }
                }
            }
        }
    }

    private func slotRow(_ slot: FreeSlot) -> some View {
        let isSelected = slot.id == selectedSlotID
        let timeRange = "\(Self.timeFmt.string(from: slot.start)) – \(Self.timeFmt.string(from: slot.end))"

        return Button {
            selectedSlotID = slot.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 18)

                Text(timeRange)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color(nsColor: .labelColor))

                Spacer()
            }
            .padding(.horizontal, 12)
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
