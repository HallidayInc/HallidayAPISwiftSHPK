import CoreText
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // Presented covers need a concrete scheme: a nil preference cannot clear an override
    // that is already applied to the window, so System left them showing the stale one.
    // UIScreen traits report the device setting and are not affected by our override.
    var resolved: ColorScheme {
        switch self {
        case .system: UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Color {
    static let crtGreen = Color(red: 61 / 255, green: 245 / 255, blue: 123 / 255)
    static let crtInk = Color(red: 11 / 255, green: 74 / 255, blue: 35 / 255)
    // Green glyphs only on dark; on light they are black.
    static let crtGlyph = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 61 / 255, green: 245 / 255, blue: 123 / 255, alpha: 1)
            : .black
    })
    static let card = Color(.secondarySystemBackground)
    // The notification badge, per the spec's red dot.
    static let badge = Color(red: 0.94, green: 0.18, blue: 0.18)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func make(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? make(dark) : make(light) })
    }

    // Full-width pill, per spec.
    static let pillFill = dynamic(light: 0xF5F5F5, dark: 0x141414)
    static let pillEdge = dynamic(light: 0xECECEC, dark: 0x262626)
    static let pillDisabledFill = dynamic(light: 0xECECEC, dark: 0x262626)
    static let pillDisabledLabel = dynamic(light: 0x565656, dark: 0x9D9D9D)
    static let surface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)
            : .white
    })
    static let hairline = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255, alpha: 1)
            : UIColor(red: 0xEC / 255, green: 0xEC / 255, blue: 0xEC / 255, alpha: 1)
    })
}

enum Theme {
    private static let tracking: CGFloat = -0.013

    static func registerFonts() {
        for name in ["HafferRegular", "HafferMedium"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        applyUIKitFonts()
    }

    // Navigation titles, bar buttons and the search field are drawn by UIKit, so they need
    // configuring separately from the SwiftUI font environment.
    private static func applyUIKitFonts() {
        guard let medium = UIFont(name: "Haffer-Medium", size: 17),
              let large = UIFont(name: "Haffer-Medium", size: 32),
              let regular = UIFont(name: "Haffer-Regular", size: 17) else { return }

        let bar = UINavigationBar.appearance().standardAppearance
        bar.titleTextAttributes[.font] = medium
        bar.largeTitleTextAttributes[.font] = large
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar

        // Without this the bar keeps the system accent, and a toolbar button's press
        // highlight comes back blue however the SwiftUI view is tinted.
        UINavigationBar.appearance().tintColor = UIColor(Color.crtGreen)

        UIBarButtonItem.appearance().setTitleTextAttributes([.font: regular], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: regular], for: .normal)
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).font = regular
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom(weight == .regular ? "Haffer-Regular" : "Haffer-Medium", size: size)
    }

    static func tracking(_ size: CGFloat) -> CGFloat {
        size * tracking
    }
}

extension View {
    func haffer(_ size: CGFloat, _ weight: Font.Weight = .medium) -> some View {
        font(Theme.font(size, weight)).tracking(Theme.tracking(size))
    }
}

enum NavGlyph: String {
    case close = "xmark"
    case back = "chevron.left"
    case forward = "chevron.right"
    case menu = "line.3.horizontal"
    case notify = "scroll"

    var label: String {
        switch self {
        case .close: "Close"
        case .back: "Back"
        case .forward: "Forward"
        case .menu: "Menu"
        case .notify: "History"
        }
    }
}

struct NavButton: View {
    enum Fill { case ghost, filled }

    let glyph: NavGlyph
    var fill: Fill = .filled
    var disabled = false
    var dot = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    // Resolved from SwiftUI's environment rather than left to .primary. These buttons live
    // in a UINavigationBar, and a dynamic colour there is resolved against UIKit traits,
    // which on first launch have not yet received the app's preferredColorScheme — so the
    // glyph rendered neutral until some later trait change corrected it.
    private var ink: Color { scheme == .dark ? .white : .black }

    var body: some View {
        Button(action: action) {
            // SF Symbols' line.3.horizontal is short and heavy; the spec's rule is thin and
            // wide, so the menu glyph is drawn rather than borrowed.
            if glyph == .menu {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(ink).frame(width: 17, height: 1.6)
                    }
                }
            } else {
                Image(systemName: glyph.rawValue)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ink)
            }
        }
        .buttonStyle(Style(fill: fill, ringed: hovering, dot: dot))
        .tint(Color.crtGreen)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(glyph.label)
    }

    private struct Style: ButtonStyle {
        let fill: Fill
        let ringed: Bool
        let dot: Bool
        private let diameter: CGFloat = 36

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(width: diameter, height: diameter)
                .background { if fill == .filled { Circle().fill(Color.card) } }
                // Hover, press and focus all read as a green ring, so the glyph never moves.
                .overlay {
                    if configuration.isPressed || ringed {
                        Circle().strokeBorder(Color.crtGreen, lineWidth: 2)
                    }
                }
                // The badge rides the corner of the button's own box rather than hanging
                // outside it: the toolbar clips anything beyond these bounds. A 36pt circle
                // inscribed in a 36pt square leaves the corners free, so it still reads as
                // sitting proud of the bell.
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle()
                            .fill(Color.badge)
                            .frame(width: 9, height: 9)
                            .offset(x: -1, y: 1)
                    }
                }
        }
    }
}

extension View {
    // iOS 26 draws a shared glass background behind toolbar items, which shows up as a ring
    // around our own circle. sharedBackgroundVisibility removes it, but ToolbarContent cannot
    // be branched on availability, so the whole toolbar is built twice.
    @ViewBuilder
    func navBar(
        leading: NavGlyph? = nil,
        onLeading: (() -> Void)? = nil,
        trailing: NavGlyph? = nil,
        onTrailing: (() -> Void)? = nil,
        trailingDot: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let leading, let onLeading { NavButton(glyph: leading, action: onLeading) }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    if let trailing, let onTrailing {
                        NavButton(glyph: trailing, dot: trailingDot, action: onTrailing)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let leading, let onLeading { NavButton(glyph: leading, action: onLeading) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let trailing, let onTrailing {
                        NavButton(glyph: trailing, dot: trailingDot, action: onTrailing)
                    }
                }
            }
        }
    }
}

struct PillButton: View {
    let title: String
    var disabled = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(Style(title: title, disabled: disabled, busy: busy))
            .disabled(disabled || busy)
    }

    private struct Style: ButtonStyle {
        let title: String
        let disabled: Bool
        let busy: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed && !disabled
            return Group {
                if busy {
                    GridWave(cell: 5, gap: 3)
                } else {
                    Text(title)
                        .haffer(17)
                        .foregroundStyle(label(pressed))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(fill(pressed), in: .capsule)
            // The edge only exists on the default state; pressed and disabled are flat.
            .overlay {
                if !pressed && !disabled {
                    Capsule().strokeBorder(Color.pillEdge, lineWidth: 1)
                }
            }
            .scaleEffect(pressed ? 0.98 : 1)
        }

        private func label(_ pressed: Bool) -> Color {
            if disabled { return .pillDisabledLabel }
            return pressed ? .crtInk : .primary
        }

        private func fill(_ pressed: Bool) -> Color {
            if disabled { return .pillDisabledFill }
            return pressed ? .crtGreen : .pillFill
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(Style(title: title, icon: icon))
    }

    // Optical centring. A symbol's ink sits where the drawing says, not in the middle of its
    // box: arrow.down carries its head low, paperplane leans up and to the right. Each nudge
    // is the measured offset of that symbol's ink mass, negated.
    fileprivate static let nudges: [String: CGSize] = [
        "arrow.down": CGSize(width: 0.3, height: 0),
        "arrow.up": CGSize(width: 0.45, height: 0),
        "arrow.left.arrow.right": CGSize(width: 0, height: 0),
        "paperplane": CGSize(width: -1, height: 0.9),
        "qrcode": CGSize(width: 0, height: 0),
    ]

    private struct Style: ButtonStyle {
        let title: String
        let icon: String
        private let diameter: CGFloat = 56
        private let glyph: CGFloat = 21
        private var nudge: CGSize { ActionButton.nudges[icon] ?? .zero }

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            return VStack(spacing: 8) {
                // Sized by ink rather than point size: at a common point size these symbols
                // draw to noticeably different heights, which reads as uneven.
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .foregroundStyle(pressed ? Color.crtInk : Color.crtGlyph)
                    .frame(width: glyph, height: glyph)
                    .offset(x: nudge.width, y: nudge.height)
                    .frame(width: diameter, height: diameter)
                    .background(pressed ? Color.crtGreen : Color.card, in: .circle)
                Text(title)
                    .haffer(12, pressed ? .medium : .regular)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
