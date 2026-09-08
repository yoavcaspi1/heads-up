import SwiftUI
import AppKit

// Settings UI building blocks, ported from the Call Recorder preferences
// pane so both apps read as one family (YC DESIGN SYSTEM, COMPONENT
// SPECS/17_PREFERENCES_PANE.md): one Harbor accent, warm neutral surfaces,
// neutral-wash hover/selection, dusty feedback tints. No second accent hue.

private typealias YC = YCDesignSystem

// MARK: - Sidebar Row

/// A sidebar row: ink SF Symbol + label. The active tab is the only
/// accent-filled element in the sidebar (Harbor fill, white text); hover
/// uses the neutral selection wash, never colour.
struct SettingsSidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? YC.Colors.textOnAccent : YC.Colors.textSecondary)
                .frame(width: 20)

            Text(title)
                .font(YC.Typography.body)
                .foregroundStyle(isSelected ? YC.Colors.textOnAccent : YC.Colors.textPrimary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: YC.CornerRadius.medium)
                .fill(isSelected
                      ? AnyShapeStyle(YC.Colors.accent)
                      : (isHovered ? AnyShapeStyle(YC.Colors.selectionHighlight) : AnyShapeStyle(Color.clear)))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(YC.Motion.microAnimation, value: isHovered)
    }
}

// MARK: - Section header, card, section

/// Uppercase eyebrow label above each card (YC `type.label` role).
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(YC.Typography.label)
            .tracking(0.8)
            .foregroundStyle(YC.Colors.textMuted)
            .padding(.leading, 4)
            .padding(.bottom, 4)
    }
}

/// A surface card containing a vertical stack of rows: `radius.container`
/// (12pt), hairline border, resting elevation.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: YC.CornerRadius.large)
                .fill(YC.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: YC.CornerRadius.large)
                .stroke(YC.Colors.border, lineWidth: 1)
        )
        .ycShadow(YC.Shadows.resting)
    }
}

/// A complete section: eyebrow header plus card.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader(title: title)
            SettingsCard {
                content()
            }
        }
    }
}

// MARK: - Settings Row

/// A single row within a settings card: label (+ optional helper line) on
/// the left, control on the right, minimum 48pt tall, hairline divider.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let showDivider: Bool
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: subtitle != nil ? .top : .center, spacing: YC.Spacing.smd) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(YC.Typography.body)
                        .foregroundStyle(YC.Colors.textPrimary)

                    if let subtitle {
                        Text(subtitle)
                            .font(YC.Typography.bodySmall)
                            .foregroundStyle(YC.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                trailing()
            }
            .padding(.horizontal, YC.Spacing.md)
            .padding(.vertical, YC.Spacing.smd)
            .frame(minHeight: 48)

            if showDivider {
                Rectangle()
                    .fill(YC.Colors.border)
                    .frame(height: 1)
                    .padding(.leading, YC.Spacing.md)
            }
        }
    }
}

// MARK: - Status Pill

/// A tinted capsule showing a read-only value (e.g. "Sign-in expired").
/// Pass a YC feedback text colour; the fill is derived from it.
struct StatusPill: View {
    let text: String
    var color: Color = YCDesignSystem.Colors.textSecondary
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(YC.Typography.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Controls

/// A toggle switch, Harbor when on.
struct SettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .tint(YC.Colors.accent)
            .labelsHidden()
    }
}

/// A dropdown picker styled for settings.
struct SettingsPicker<T: Hashable, Content: View>: View {
    let selection: Binding<T>
    @ViewBuilder let content: () -> Content

    var body: some View {
        Picker("", selection: selection) {
            content()
        }
        .labelsHidden()
        .tint(YC.Colors.accent)
        .frame(maxWidth: 200)
    }
}

/// Secondary action button in the YC voice: outlined, ink text, never a
/// second accent hue. Destructive actions use the danger feedback pair.
struct SettingsButton: View {
    let title: String
    var icon: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(title)
                    .font(YC.Typography.button)
            }
            .foregroundStyle(isDestructive ? YC.Colors.dangerText : YC.Colors.actionSecondary)
            .padding(.horizontal, YC.Spacing.smd)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: YC.CornerRadius.medium)
                    .fill(isHovered
                          ? (isDestructive ? YC.Colors.dangerBg : YC.Colors.selectionHighlight)
                          : YC.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: YC.CornerRadius.medium)
                    .stroke(isDestructive ? YC.Colors.dangerText.opacity(0.4) : YC.Colors.borderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(YC.Motion.microAnimation, value: isHovered)
    }
}

/// Primary button per the YC button spec: Harbor fill, white text,
/// `radius.control` corners.
struct YCPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(YC.Typography.button)
            .foregroundStyle(isEnabled ? YC.Colors.textOnAccent : YC.Colors.disabledText)
            .padding(.horizontal, YC.Spacing.smd)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: YC.CornerRadius.medium)
                    .fill(isEnabled
                          ? (configuration.isPressed ? YC.Colors.accentActive : YC.Colors.accent)
                          : YC.Colors.disabledBg)
            )
            .animation(YC.Motion.microAnimation, value: configuration.isPressed)
    }
}

/// Secondary button per the YC voice: outlined, ink text.
struct YCSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(YC.Typography.button)
            .foregroundStyle(isEnabled ? YC.Colors.actionSecondary : YC.Colors.disabledText)
            .padding(.horizontal, YC.Spacing.smd)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: YC.CornerRadius.medium)
                    .fill(configuration.isPressed ? YC.Colors.selectionHighlightStrong : YC.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: YC.CornerRadius.medium)
                    .stroke(YC.Colors.borderStrong, lineWidth: 1)
            )
            .animation(YC.Motion.microAnimation, value: configuration.isPressed)
    }
}

// MARK: - Detail pane

/// Container for the detail pane: canvas background, cards float on top.
struct SettingsDetailPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YC.Spacing.lg) {
                content()
            }
            .padding(YC.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YC.Colors.canvas)
    }
}

// MARK: - Callout

/// A section-level message with a severity (COMPONENT SPECS/10_CALLOUT.md):
/// tinted background, coloured left border, an icon and a word naming the
/// severity. Never colour-only: the icon and the leading word both carry
/// the meaning for anyone who cannot see the tint.
struct SettingsCallout: View {
    enum Severity {
        case info, warning, danger

        var word: String {
            switch self {
            case .info: return "Note:"
            case .warning: return "Warning:"
            case .danger: return "Error:"
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "octagon.fill"
            }
        }

        var textColor: Color {
            switch self {
            case .info: return YC.Colors.infoText
            case .warning: return YC.Colors.warningText
            case .danger: return YC.Colors.dangerText
            }
        }

        var background: Color {
            switch self {
            case .info: return YC.Colors.infoBg
            case .warning: return YC.Colors.warningBg
            case .danger: return YC.Colors.dangerBg
            }
        }
    }

    let severity: Severity
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: YC.Spacing.sm) {
            Image(systemName: severity.icon)
                .font(.system(size: 12))
                .foregroundStyle(severity.textColor)
                .padding(.top, 1)

            Text("\(severity.word) \(message)")
                .font(.system(size: 11))
                .foregroundStyle(severity.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, YC.Spacing.smd)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(severity.background)
                Rectangle().fill(severity.textColor).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        )
    }
}
