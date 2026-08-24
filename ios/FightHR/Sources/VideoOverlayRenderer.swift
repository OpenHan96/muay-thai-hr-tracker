import CoreImage
import UIKit

/// Draws the badge burned into recorded frames. Kept separate from capture so
/// its final pixel orientation can be tested in the iOS Simulator.
enum VideoOverlayRenderer {
    /// Z1...Z5 fills, mirroring Theme.zoneColors for UIKit drawing.
    private static let zoneFill: [UIColor] = [
        UIColor(red: 0x5d / 255.0, green: 0x8a / 255.0, blue: 0xa8 / 255.0, alpha: 1),
        UIColor(red: 0x2a / 255.0, green: 0x9d / 255.0, blue: 0x8f / 255.0, alpha: 1),
        UIColor(red: 0xe9 / 255.0, green: 0xc4 / 255.0, blue: 0x6a / 255.0, alpha: 1),
        UIColor(red: 0xf4 / 255.0, green: 0xa2 / 255.0, blue: 0x61 / 255.0, alpha: 1),
        UIColor(red: 0xe6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 1),
    ]

    static func pillLabel(bpm: Int, zone: Int) -> String {
        guard bpm > 0 else { return "NO SIGNAL" }
        guard zone >= 0 else { return "WARM-UP" }
        let parts = Theme.zoneNames[zone].split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? "\(parts[0]) · \(String(parts[1]).uppercased())"
                               : Theme.zoneNames[zone].uppercased()
    }

    static func renderBadge(bpm: Int, zone: Int, scale: CGFloat) -> CIImage {
        let hasHR = bpm > 0
        let pad: CGFloat = 30, gap: CGFloat = 16

        let numFont: UIFont = {
            let f = UIFont.monospacedDigitSystemFont(ofSize: 110, weight: .heavy)
            guard let d = f.fontDescriptor.withDesign(.rounded) else { return f }
            return UIFont(descriptor: d, size: 110)
        }()
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: 3)
        let numText = hasHR ? "\(bpm)" : "--"
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: numFont, .foregroundColor: UIColor.white, .shadow: shadow,
        ]
        let numSize = (numText as NSString).size(withAttributes: numAttrs)

        let bpmFont = UIFont.systemFont(ofSize: 30, weight: .bold)
        let bpmAttrs: [NSAttributedString.Key: Any] = [
            .font: bpmFont, .foregroundColor: UIColor(white: 1, alpha: 0.55), .kern: 3,
        ]
        let bpmSize = ("BPM" as NSString).size(withAttributes: bpmAttrs)

        let heartCfg = UIImage.SymbolConfiguration(pointSize: 58, weight: .bold)
        let heartTint = hasHR ? zoneFill[4] : UIColor(white: 1, alpha: 0.35)
        let heart = UIImage(systemName: "heart.fill", withConfiguration: heartCfg)?
            .withTintColor(heartTint, renderingMode: .alwaysOriginal)
        let heartSz = heart?.size ?? CGSize(width: 58, height: 52)

        let pillText = pillLabel(bpm: bpm, zone: zone)
        let inZone = hasHR && zone >= 0
        let darkText = zone == 2 || zone == 3
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 33, weight: .heavy),
            .foregroundColor: inZone
                ? (darkText ? UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1) : UIColor.white)
                : UIColor(white: 1, alpha: 0.7),
            .kern: 1.5,
        ]
        let pillTextSize = (pillText as NSString).size(withAttributes: pillAttrs)
        let pillFill: UIColor = inZone ? zoneFill[zone] : UIColor(white: 1, alpha: 0.15)
        let pillH = pillTextSize.height + 26
        let pillW = pillTextSize.width + 54

        let row1H = max(heartSz.height, numSize.height)
        let row1W = heartSz.width + 22 + numSize.width + 16 + bpmSize.width
        let width = max(row1W, pillW) + pad * 2
        let height = pad + row1H + gap + pillH + pad

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { _ in
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                         cornerRadius: 34).fill()

            var x = pad
            heart?.draw(at: CGPoint(x: x, y: pad + (row1H - heartSz.height) / 2))
            x += heartSz.width + 22

            let numY = pad + (row1H - numSize.height) / 2
            (numText as NSString).draw(at: CGPoint(x: x, y: numY), withAttributes: numAttrs)

            let bpmY = numY + numFont.ascender - bpmFont.ascender
            ("BPM" as NSString).draw(at: CGPoint(x: x + numSize.width + 16, y: bpmY),
                                     withAttributes: bpmAttrs)

            let pillY = pad + row1H + gap
            pillFill.setFill()
            UIBezierPath(roundedRect: CGRect(x: pad, y: pillY, width: pillW, height: pillH),
                         cornerRadius: pillH / 2).fill()
            (pillText as NSString).draw(
                at: CGPoint(x: pad + (pillW - pillTextSize.width) / 2,
                            y: pillY + (pillH - pillTextSize.height) / 2),
                withAttributes: pillAttrs)
        }

        // CIImage(image:) already preserves the upright UIKit bitmap when it
        // is rendered into the writer's pixel buffer. A second Y-axis flip
        // inverted the saved BPM badge even though the live SwiftUI badge was
        // correct.
        return CIImage(image: image) ?? CIImage.empty()
    }
}
