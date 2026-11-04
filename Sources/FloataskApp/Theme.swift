import AppKit
import SwiftUI

/// Calm, low-contrast-chrome / high-contrast-text palette. One accent (sage) for progress and
/// completion; amber appears only while a focus session is running.
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background   = dynamic(0xF3F1ED, 0x1E1D1B)
    static let surface      = dynamic(0xFBFAF8, 0x272624)
    static let surfaceHover = dynamic(0xEEEBE6, 0x302F2C)
    static let border       = dynamic(0xE3DFD8, 0x383633)
    static let text         = dynamic(0x2A2927, 0xECE9E4)
    static let secondary    = dynamic(0x6F6B65, 0xA6A199)
    static let tertiary     = dynamic(0xA19C94, 0x6C6862)
    static let accent       = dynamic(0x5E8463, 0x8DB291)   // sage
    static let accentSoft   = dynamic(0xDFE8DD, 0x2E3A2F)
    static let focus        = dynamic(0xB9782F, 0xE3A75E)   // amber, only while running
    static let focusSoft    = dynamic(0xF6EBDC, 0x3A3024)
    static let danger       = dynamic(0xB0493F, 0xE08A80)
    static let checkbox     = dynamic(0x8C877F, 0x8A857D)

    static func label(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(secondary)
    }

    static let radius: CGFloat = 14
    static let timerFont = Font.system(size: 42, weight: .medium, design: .rounded).monospacedDigit()
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Small plain icon button used throughout (header, footer, rows).
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 13
    var tint: Color = Theme.secondary
    let action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hover ? Theme.text : tint)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.surfaceHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Text-style button with a quiet hover background.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, prominent: prominent, tint: tint)
    }

    private struct QuietButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        @ViewState private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(prominent ? tint.opacity(configuration.isPressed ? 0.8 : (hover ? 0.92 : 1))
                                        : (hover || configuration.isPressed ? Theme.surfaceHover : Color.clear))
                )
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// The macOS 26 SDK declares `@State` as a macro whose plugin ships only with Xcode. Building with the
/// Command Line Tools, we reach the underlying property wrapper through this alias instead.
typealias ViewState<Value> = SwiftUI.State<Value>

/// The Floatask mark, drawn from the two layers in Resources so it follows light/dark mode:
/// the frame takes the text colour, the wave takes the accent (amber while a focus session runs).
struct LogoMark: View {
    var size: CGFloat = 16
    var wave: Color = Theme.accent

    private static func layer(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
    private static let frameImage = layer("LogoFrame")
    private static let waveImage = layer("LogoWave")

    var body: some View {
        ZStack {
            if let f = LogoMark.frameImage, let w = LogoMark.waveImage {
                Image(nsImage: f).resizable().foregroundStyle(Theme.text)
                Image(nsImage: w).resizable().foregroundStyle(wave)
            } else {
                Circle().fill(wave).frame(width: size / 2, height: size / 2)
            }
        }
        .aspectRatio(218 / 221, contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
