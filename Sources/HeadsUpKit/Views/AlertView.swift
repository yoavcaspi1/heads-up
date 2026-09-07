import SwiftUI

/// Duration humaniser reused by the snooze row's button labels. Internal
/// (not private) so checks can cover it directly.
func humanizeDuration(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
    let hours = minutes / 60
    let mins = minutes % 60
    let hourPart = "\(hours) hour\(hours == 1 ? "" : "s")"
    return mins > 0 ? "\(hourPart) \(mins) minute\(mins == 1 ? "" : "s")" : hourPart
}

struct AlertView: View {
    let event: CalendarEvent
    let snoozeDurations: [Int]
    let titleFontChoice: AppSettings.AlertTitleFont
    let onJoin: () -> Void
    let onDismiss: () -> Void
    let onSnooze: (Int) -> Void

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    private let extraSnooze = [10, 15, 30, 60]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack {
                Spacer()
                hero(now: now)
                Spacer()
                snoozeRow(now: now)
                    .padding(.bottom, YCDesignSystem.Spacing.xxl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hero(now: Date) -> some View {
        VStack(spacing: YCDesignSystem.Spacing.lg) {
            // The full title must ALWAYS be visible: no line limit, and
            // long titles step down to a smaller type size instead of
            // truncating. Deliberately NO minimumScaleFactor and NO
            // fixedSize here: each has independently made the live render
            // shave glyph bottoms/tops on multi-line Syne (minimumScaleFactor
            // in build 11, fixedSize again in build 13; offscreen renders
            // look fine, only the on-screen compositor clips). Without
            // fixedSize a greedy sibling would stretch to the proposed
            // height - build 14's floor-to-ceiling accent bar - so the bar
            // is an overlay: its height is the text's own height by
            // construction, whatever the layout proposes.
            Text(event.title)
                .font(titleFont)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .padding(.vertical, YCDesignSystem.Spacing.xs)
                .padding(.leading, 6 + YCDesignSystem.Spacing.md)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.pill)
                        .fill(YCDesignSystem.Colors.accent)
                        .frame(width: 6)
                }
                .frame(maxWidth: 900)

            VStack(spacing: YCDesignSystem.Spacing.xs) {
                Text("\(Self.clock.string(from: event.start)) - \(Self.clock.string(from: event.end))")
                    .font(YCDesignSystem.Typography.dataLarge)
                    .foregroundStyle(YCDesignSystem.Colors.textPrimary)
                Text(countdownLine(now: now))
                    .font(YCDesignSystem.Typography.bodyLarge)
                    .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                // A location that is just the meeting URL duplicates the
                // Join button as a clipped link string; show only genuine
                // locations here.
                if let location = event.location, location != event.meetingUrl {
                    Text(location)
                        .font(YCDesignSystem.Typography.body)
                        .foregroundStyle(YCDesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 480)
                }
            }

            RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.large)
                .fill(YCDesignSystem.Colors.surface)
                .overlay(RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.large)
                    .stroke(YCDesignSystem.Colors.border, lineWidth: 1))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: event.meetingUrl != nil ? "video" : "calendar")
                    .font(.system(size: 22))
                    .foregroundStyle(YCDesignSystem.Colors.textSecondary))

            // Join and Dismiss are one fixed-size pair: same width, height
            // and corner radius, differing only in fill (primary vs
            // secondary). Dismiss becomes the primary when there is nothing
            // to join.
            VStack(spacing: YCDesignSystem.Spacing.smd) {
                if event.meetingUrl != nil {
                    actionButton("Join meeting", icon: "video", primary: true, action: onJoin)
                }
                actionButton("Dismiss", icon: nil, primary: event.meetingUrl == nil, action: onDismiss)
            }
            .padding(.top, YCDesignSystem.Spacing.sm)
        }
    }

    private static let actionButtonWidth: CGFloat = 240
    private static let actionButtonHeight: CGFloat = 44

    private func actionButton(_ title: String, icon: String?, primary: Bool,
                              action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium)
        return Button(action: action) {
            HStack(spacing: YCDesignSystem.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(YCDesignSystem.Typography.button)
            .foregroundStyle(primary ? YCDesignSystem.Colors.textOnAccent : YCDesignSystem.Colors.textPrimary)
            .frame(width: Self.actionButtonWidth, height: Self.actionButtonHeight)
            .background(primary
                ? AnyShapeStyle(YCDesignSystem.Colors.accent)
                : AnyShapeStyle(YCDesignSystem.Colors.surfaceAlt))
            .overlay(shape.stroke(primary ? Color.clear : YCDesignSystem.Colors.borderStrong, lineWidth: 1))
            .clipShape(shape)
        }
        .buttonStyle(.plain)
    }

    /// Hero title size steps down with title length so any title fits fully.
    private var titleFont: Font {
        let count = event.title.count
        let syne = titleFontChoice == .syne
        if count > 110 { return syne ? YCDesignSystem.Typography.h1 : YCDesignSystem.Typography.h1Sans }
        if count > 55 { return syne ? YCDesignSystem.Typography.display : YCDesignSystem.Typography.displaySans }
        return syne ? YCDesignSystem.Typography.displayXL : YCDesignSystem.Typography.displayXLSans
    }

    private func countdownLine(now: Date) -> String {
        if event.isTest { return "This is a preview alert" }
        let diffMin = Int((event.start.timeIntervalSince(now) / 60).rounded())
        if diffMin <= 0 { return "The event is starting now" }
        return "The event will start in \(humanizeDuration(diffMin))"
    }

    private func snoozeRow(now: Date) -> some View {
        let minutesUntilStart = min(120, max(1, Int(ceil(event.start.timeIntervalSince(now) / 60))))
        // Spec: "Until event" is disabled when under 90 seconds remain, so
        // exactly 90 seconds must still be enabled.
        let canSnoozeUntilEvent = event.start.timeIntervalSince(now) >= 90
        let first = snoozeDurations.first ?? 1
        let second = snoozeDurations.count > 1 ? snoozeDurations[1] : 5
        return VStack(spacing: YCDesignSystem.Spacing.sm) {
            Text("Snooze")
                .font(YCDesignSystem.Typography.label)
                .foregroundStyle(YCDesignSystem.Colors.textSecondary)
            HStack(spacing: YCDesignSystem.Spacing.sm) {
                snoozeButton(humanizeDuration(first)) { onSnooze(first) }
                snoozeButton(humanizeDuration(second)) { onSnooze(second) }
                snoozeButton("Until event", disabled: !canSnoozeUntilEvent) { onSnooze(minutesUntilStart) }
                Menu {
                    ForEach(extraSnooze.filter { $0 != first && $0 != second }, id: \.self) { m in
                        Button(humanizeDuration(m)) { onSnooze(m) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(YCDesignSystem.Typography.button)
                        .foregroundStyle(YCDesignSystem.Colors.textPrimary)
                        .frame(width: 44, height: 36)
                        .background(YCDesignSystem.Colors.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func snoozeButton(_ title: String, disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(YCDesignSystem.Typography.button)
                .foregroundStyle(disabled
                    ? YCDesignSystem.Colors.disabledText : YCDesignSystem.Colors.textPrimary)
                .padding(.horizontal, YCDesignSystem.Spacing.md)
                .frame(height: 36)
                .background(disabled
                    ? YCDesignSystem.Colors.disabledBg : YCDesignSystem.Colors.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
