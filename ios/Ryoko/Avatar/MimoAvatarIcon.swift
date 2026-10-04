import SwiftUI
import UIKit

/// Mimo's rest pose as a template image, for the tab bar (25 to 28 pt).
///
///     Label { Text("Mimo") } icon: { MimoAvatarIcon.image() }
///
/// `.filled` is the avatar itself: the body solid, the eyes cut out. `.outline` strokes the
/// body and fills the eyes, to sit with outline SF Symbols. Both are templates, so the tab
/// bar tints them.
enum MimoAvatarIcon {
    enum Variant: Sendable {
        case filled
        case outline
    }

    /// Apple's guideline size for a round custom tab bar glyph.
    static let tabBarPointSize: CGFloat = 25

    static func image(pointSize: CGFloat = tabBarPointSize, variant: Variant = .filled, style: MimoAvatarStyle = .mimo) -> Image {
        if let ui = uiImage(pointSize: pointSize, variant: variant, style: style) {
            return Image(uiImage: ui).renderingMode(.template)
        }
        return Image(systemName: "bubble.left")
    }

    /// Rendered once per size, variant and style, through `ImageRenderer`.
    static func uiImage(pointSize: CGFloat = tabBarPointSize, variant: Variant = .filled, style: MimoAvatarStyle = .mimo,
                        scale: CGFloat = 3) -> UIImage?
    {
        let key = CacheKey(pointSize: pointSize, variant: variant, style: style, scale: scale)
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content: MimoAvatarIconGlyph(variant: variant, style: style)
            .frame(width: pointSize, height: pointSize))
        renderer.scale = scale
        renderer.isOpaque = false
        let image = renderer.uiImage?.withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }

    private struct CacheKey: Hashable {
        var pointSize: CGFloat
        var variant: Variant
        var style: MimoAvatarStyle
        var scale: CGFloat
    }

    private static var cache: [CacheKey: UIImage] = [:]
}

/// The rest pose, framed tight on the body (no room for rings in an icon).
struct MimoAvatarIconGlyph: View {
    var variant: MimoAvatarIcon.Variant
    var style: MimoAvatarStyle

    var body: some View {
        let frame = MimoAvatarDirector.frozen(.idle, at: Bloub.poseTimes[.idle] ?? 1, style: style)
        Canvas { context, size in
            // the body's widest reach, plus a hair for antialiasing
            let reach = frame.body.map { max(abs($0.x), abs($0.y)) }.max() ?? 1
            switch variant {
            case .filled:
                MimoAvatarRenderer.paint(frame, in: context, size: size, extent: reach * 1.02,
                                         ink: .color(.black), ringGap: style.ringGap)
            case .outline:
                let weight = 0.085 // of the icon's side: about SF Symbols' regular stroke at 25 pt
                let extent = reach / (1 - weight)
                var gc = context
                let k = min(size.width, size.height) / (2 * extent)
                gc.translateBy(x: size.width / 2, y: size.height / 2)
                gc.scaleBy(x: k, y: k)
                gc.stroke(MimoAvatarRenderer.bodyPath(frame), with: .color(.black),
                          style: StrokeStyle(lineWidth: weight * 2 * extent, lineJoin: .round))
                var eyes = gc
                eyes.clip(to: MimoAvatarRenderer.bodyPath(frame))
                for eye in frame.eyes {
                    eyes.fill(MimoAvatarRenderer.eyePath(eye), with: .color(.black))
                }
            }
        }
    }
}
