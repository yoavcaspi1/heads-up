import SwiftUI
import AppKit

/// One "scroll the list to today" request. A fresh `id` per request means
/// opening the popover twice in a row still fires onChange the second time.
struct CalendarScrollRequest: Equatable {
    let id = UUID()
}

final class CalendarListModel: ObservableObject {
    @Published var events: [CalendarEvent] = []
    @Published var configured = false
    @Published var connected = false
    @Published var needsReconnect = false
    @Published var scrollRequest: CalendarScrollRequest?

    private let scheduler: Scheduler
    private let registry: GoogleAccountsRegistry
    private let credentials: GoogleCredentialsStore

    init(scheduler: Scheduler, registry: GoogleAccountsRegistry, credentials: GoogleCredentialsStore) {
        self.scheduler = scheduler
        self.registry = registry
        self.credentials = credentials
        scheduler.onEventsChanged { [weak self] in DispatchQueue.main.async { self?.reload() } }
        scheduler.onAccountsStateChanged { [weak self] in DispatchQueue.main.async { self?.reload() } }
        reload()
    }

    func reload() {
        events = scheduler.cachedEvents
        configured = credentials.isConfigured
        connected = configured && registry.hasAccounts
        needsReconnect = registry.anyAccountNeedsReconnect
    }

    /// Ask the list to put today at the top. Issued on every open.
    func requestScrollToToday() {
        scrollRequest = CalendarScrollRequest()
    }

    /// The section id the list scrolls to on open: today. Every day in the
    /// window has a section now, empty or not, so today always exists once
    /// the list is populated; the "first day at or after today" fallback
    /// only matters for an empty list. Pure, so checks can cover it.
    static func scrollTargetId(sections: [(dayOffset: Int, date: Date, events: [CalendarEvent])]) -> String? {
        guard let anchor = sections.first(where: { $0.dayOffset >= 0 })?.dayOffset else { return nil }
        return Self.sectionId(forDayOffset: anchor)
    }

    static func sectionId(forDayOffset offset: Int) -> String { "day-\(offset)" }

    /// One section per local day from a week ago to a week ahead, ascending,
    /// with that day's events (possibly none: empty days still get a
    /// section so the list reads as a continuous fortnight).
    var sections: [(dayOffset: Int, date: Date, events: [CalendarEvent])] {
        Self.bucketed(events, today: Date(), calendar: .current)
    }

    static let dayWindow = -7...7

    /// Pure bucketing: every day offset in `dayWindow` gets a section, and
    /// each event lands in its local day's section; events outside the
    /// window are dropped. Pulled out of the `sections` instance property
    /// so checks can exercise the real bucketing code path directly.
    static func bucketed(_ events: [CalendarEvent], today: Date, calendar: Calendar) -> [(dayOffset: Int, date: Date, events: [CalendarEvent])] {
        let startOfToday = calendar.startOfDay(for: today)
        var buckets: [Int: [CalendarEvent]] = [:]
        for e in events {
            let day = calendar.startOfDay(for: e.start)
            let diff = calendar.dateComponents([.day], from: startOfToday, to: day).day ?? 0
            if dayWindow.contains(diff) { buckets[diff, default: []].append(e) }
        }
        return dayWindow.map { offset in
            (offset, calendar.date(byAdding: .day, value: offset, to: startOfToday)!, buckets[offset] ?? [])
        }
    }

    static func dayLabel(offset: Int, date: Date) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let f = DateFormatter()
            f.dateFormat = "EEEE d MMM"
            return f.string(from: date)
        }
    }
}

struct CalendarListView: View {
    /// Opens a clicked event in whichever calendar app the settings choose.
    let onOpenEvent: (CalendarEvent) -> Void
    @ObservedObject var model: CalendarListModel
    let onOpenSettings: () -> Void

    /// Fixed content size, shared with the popover that hosts the view.
    static let size = NSSize(width: 420, height: 640)

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if model.needsReconnect && model.configured {
                reconnectCallout
            }

            if !model.configured {
                emptyState
            } else {
                eventsList
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(YCDesignSystem.Colors.canvas)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: YCDesignSystem.Spacing.sm) {
            Text("Calendar")
                .font(YCDesignSystem.Typography.h2)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .foregroundStyle(YCDesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            // As the window's first (often only) focusable control, the cog
            // gets the keyboard-focus highlight (a filled accent-tinted box)
            // whenever the panel opens. Suppress the visual; the button
            // stays clickable and tab-reachable.
            .focusEffectDisabled()
        }
        .padding(.horizontal, YCDesignSystem.Spacing.md)
        .padding(.vertical, YCDesignSystem.Spacing.smd)
    }

    // MARK: - Empty state (not configured)

    private var emptyState: some View {
        VStack(spacing: YCDesignSystem.Spacing.md) {
            Spacer()
            Text("Connect Google Calendar")
                .font(YCDesignSystem.Typography.h3)
                .foregroundStyle(YCDesignSystem.Colors.textPrimary)
            Text("Add your Google credentials in Settings to see your upcoming events here.")
                .font(YCDesignSystem.Typography.body)
                .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(action: onOpenSettings) {
                Text("Open Settings")
                    .font(YCDesignSystem.Typography.button)
                    .foregroundStyle(YCDesignSystem.Colors.textOnAccent)
                    .padding(.horizontal, YCDesignSystem.Spacing.lg)
                    .frame(height: 36)
                    .background(YCDesignSystem.Colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.medium))
            }
            .buttonStyle(.plain)
            .padding(.top, YCDesignSystem.Spacing.xs)
            Spacer()
        }
        .padding(YCDesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Reconnect callout

    private var reconnectCallout: some View {
        HStack(spacing: YCDesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(YCDesignSystem.Colors.warningText)
            Text("A Google sign-in has expired. Reconnect it in Settings.")
                .font(YCDesignSystem.Typography.bodySmall)
                .foregroundStyle(YCDesignSystem.Colors.warningText)
            Spacer()
            Button(action: onOpenSettings) {
                Text("Open Settings")
                    .font(YCDesignSystem.Typography.label)
                    .foregroundStyle(YCDesignSystem.Colors.link)
            }
            .buttonStyle(.plain)
        }
        .padding(YCDesignSystem.Spacing.smd)
        .background(
            RoundedRectangle(cornerRadius: YCDesignSystem.CornerRadius.large)
                .fill(YCDesignSystem.Colors.warningBg)
        )
        .padding(.horizontal, YCDesignSystem.Spacing.md)
        .padding(.bottom, YCDesignSystem.Spacing.sm)
    }

    // MARK: - Events list

    private var eventsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not Lazy: scrollTo needs the target section
                // to exist in the layout. Fifteen sections of a few rows each
                // is small enough that eager layout costs nothing noticeable.
                VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.md) {
                    ForEach(model.sections, id: \.dayOffset) { section in
                        sectionView(section)
                            .id(CalendarListModel.sectionId(forDayOffset: section.dayOffset))
                    }
                }
                .padding(.horizontal, YCDesignSystem.Spacing.md)
                .padding(.bottom, YCDesignSystem.Spacing.md)
            }
            // First open: the request was filed before this view existed.
            .onAppear { scrollToToday(proxy) }
            // Every later open: the popover content stays alive between
            // shows, so only the request changes.
            .onChange(of: model.scrollRequest) { _, _ in scrollToToday(proxy) }
        }
    }

    private func scrollToToday(_ proxy: ScrollViewProxy) {
        guard let target = CalendarListModel.scrollTargetId(sections: model.sections) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private func sectionView(_ section: (dayOffset: Int, date: Date, events: [CalendarEvent])) -> some View {
        let isPast = section.dayOffset < 0
        let isToday = section.dayOffset == 0
        return VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.xs) {
            Text(CalendarListModel.dayLabel(offset: section.dayOffset, date: section.date).uppercased())
                .font(YCDesignSystem.Typography.label)
                .foregroundStyle(isToday ? YCDesignSystem.Colors.accent : YCDesignSystem.Colors.textMuted)
                .padding(.top, YCDesignSystem.Spacing.sm)
            if section.events.isEmpty {
                Text("No events")
                    .font(YCDesignSystem.Typography.body)
                    .foregroundStyle(YCDesignSystem.Colors.textMuted)
                    .padding(.horizontal, YCDesignSystem.Spacing.sm)
                    .padding(.vertical, YCDesignSystem.Spacing.xs)
            } else {
                VStack(spacing: YCDesignSystem.Spacing.xs) {
                    // schedulerKey, not id: a recurring series shares one id
                    // across its instances.
                    ForEach(section.events, id: \.schedulerKey) { event in
                        EventRow(event: event, isToday: isToday, onOpen: onOpenEvent)
                    }
                }
            }
        }
        .opacity(isPast ? 0.6 : 1)
    }

    private struct EventRow: View {
        let event: CalendarEvent
        let isToday: Bool
        let onOpen: (CalendarEvent) -> Void
        @State private var hovered = false

        private static let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            return f
        }()

        var body: some View {
            Group {
                if isToday {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        rowContent(now: context.date)
                    }
                } else {
                    rowContent(now: nil)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .ycRowHighlight(isSelected: false, isHovered: hovered)
            .onTapGesture {
                onOpen(event)
            }
        }

        private func rowContent(now: Date?) -> some View {
            HStack(spacing: YCDesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: YCDesignSystem.Spacing.xs) {
                    HStack(spacing: YCDesignSystem.Spacing.xs) {
                        Text(event.title)
                            .font(YCDesignSystem.Typography.body)
                            .foregroundStyle(isToday ? YCDesignSystem.Colors.accent : YCDesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        if event.meetingUrl != nil {
                            Image(systemName: "video")
                                .imageScale(.small)
                                .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                        }
                    }
                    Text(timeRange)
                        .font(YCDesignSystem.Typography.code)
                        .foregroundStyle(YCDesignSystem.Colors.textSecondary)
                }
                Spacer()
                // Shared live label: countdown before start, "now" while in
                // progress, nothing once ended or for all-day events.
                if isToday, let now, let label = TrayModel.liveLabel(for: event, now: now) {
                    Text(label)
                        .font(YCDesignSystem.Typography.code)
                        .foregroundStyle(YCDesignSystem.Colors.accent)
                }
            }
            .padding(.horizontal, YCDesignSystem.Spacing.sm)
            .padding(.vertical, YCDesignSystem.Spacing.xs)
        }

        private var timeRange: String {
            if event.allDay { return "All day" }
            return "\(Self.timeFormatter.string(from: event.start)) - \(Self.timeFormatter.string(from: event.end))"
        }

    }
}
