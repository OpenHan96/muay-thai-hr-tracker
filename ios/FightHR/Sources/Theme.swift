import SwiftUI

/// Palette ported 1:1 from the web app's CSS variables.
enum Theme {
    static let bg      = Color(hex: 0x0d0f14)
    static let panel   = Color(hex: 0x161a22)
    static let panel2  = Color(hex: 0x1d2230)
    static let text    = Color(hex: 0xe8ebf2)
    static let muted   = Color(hex: 0x8a93a6)
    static let accent  = Color(hex: 0xe63946)
    static let good    = Color(hex: 0x2a9d8f)
    static let border  = Color(hex: 0x20273a)

    /// Z1..Z5 colors, matching ZONE_COLORS in index.html.
    static let zoneColors: [Color] = [
        Color(hex: 0x5d8aa8), Color(hex: 0x2a9d8f), Color(hex: 0xe9c46a),
        Color(hex: 0xf4a261), Color(hex: 0xe63946),
    ]
    static let zoneNames = ["Z1 Recovery", "Z2 Endurance", "Z3 Tempo", "Z4 Threshold", "Z5 Max"]
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue:  Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

/// Reusable card container matching `.card` in the web app.
struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2).bold()
                    .tracking(1)
                    .foregroundStyle(Theme.muted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }
}
