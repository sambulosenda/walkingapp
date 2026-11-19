import SwiftUI

// MARK: - Bottom sheet

/// The white card that rises from the bottom of most v2 screens, with its grabber.
struct BottomSheet<Content: View>: View {
    var bottomPadding: CGFloat = 34
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Theme.grabber)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .accessibilityHidden(true)
            content
        }
        .padding(.horizontal, 20)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Theme.sheetRadius, topTrailingRadius: Theme.sheetRadius)
                .fill(Theme.sheet)
                .shadow(color: Palette.ink.opacity(0.10), radius: 15, y: -10)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

struct SheetTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .tracking(-0.22)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StepLabel: View {
    let step: Int
    let of: Int
    var body: some View {
        Text("Step \(step) of \(of)")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.muted)
    }
}

struct BodyText: View {
    let text: String
    var size: CGFloat = 15
    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    var fontSize: CGFloat = 17
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Theme.onPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(Theme.primary))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(Capsule().fill(Theme.chip))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct TextButtonStyle: ButtonStyle {
    var size: CGFloat = 17
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Round 48 pt chip button, used for the minute stepper and the walking toolbar.
struct RoundIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 48
    var fill: Color = Theme.chip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Glass

/// Frosted floating surface over the map (the design's 78% white with an 18 pt blur).
struct Glass: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.glass)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                            .blendMode(.overlay)
                    )
                    .shadow(color: Palette.ink.opacity(0.14), radius: 12, y: 8)
            )
    }
}

extension View {
    func glass(radius: CGFloat = 22) -> some View { modifier(Glass(radius: radius)) }
}

struct GlassIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .glass(radius: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Selectable rows

/// A choice row: idle rows are a soft grey, the picked row turns white with a 2 pt ink ring.
struct ChoiceRow<Leading: View, Trailing: View>: View {
    let isSelected: Bool
    var height: CGFloat = 64
    var radius: CGFloat = Theme.rowRadius
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                trailing
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isSelected ? Theme.rowSelected : Theme.rowIdle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.text, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

struct RadioDot: View {
    let isOn: Bool
    var body: some View {
        Circle()
            .strokeBorder(isOn ? Theme.text : Theme.radioIdle, lineWidth: 2)
            .frame(width: 22, height: 22)
            .overlay(Circle().fill(isOn ? Theme.text : .clear).frame(width: 10, height: 10))
            .accessibilityHidden(true)
    }
}

struct TitleSubtitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Turn card

/// The instruction card at the top of the walking screens.
struct TurnCard: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.onPrimary)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.primary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.22)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glass(radius: 26)
        .accessibilityElement(children: .combine)
    }
}
