import AppKit
import ChiefStewCore
import SwiftUI

/// The menu-bar item: an icon plus short text. MenuBarExtra renders labels monochrome, so the
/// attention colour lives in the icon image itself (a non-template NSImage keeps its colours).
public struct MenuBarLabel: View {
    var state: MenuBarState

    public init(state: MenuBarState) { self.state = state }

    public var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(attention: state.attention, warning: state.warning))
            if let title = state.title { Text(title).monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "Chief Stew"
        if let title = state.title { text += ", \(title)" }
        if state.warning { text += ", something left behind" }
        return text
    }
}

public enum MenuBarIcon {
    static let symbol = "ferry"

    /// Template image normally; orange with a badge dot when something needs you; a small
    /// warning triangle appended when there are left-behind findings or a stale repo.
    @MainActor public static func image(attention: Bool, warning: Bool) -> NSImage {
        let key = "\(attention)-\(warning)"
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let base =
            NSImage(systemSymbolName: symbol, accessibilityDescription: "Chief Stew")?
            .withSymbolConfiguration(config) ?? NSImage()
        let triangle = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        let warnWidth: CGFloat = warning ? 11 : 0
        let size = NSSize(width: base.size.width + 3 + warnWidth, height: max(base.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let y = (rect.height - base.size.height) / 2
            let iconRect = NSRect(x: 1, y: y, width: base.size.width, height: base.size.height)
            if attention {
                tinted(base, NSColor.systemOrange).draw(in: iconRect)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: iconRect.maxX - 4.5, y: iconRect.maxY - 5.5, width: 6, height: 6)).fill()
            } else {
                tinted(base, .black).draw(in: iconRect)
            }
            if warning, let triangle {
                let t = triangle.size
                let color: NSColor = attention ? .systemOrange : .black
                tinted(triangle, color).draw(
                    in: NSRect(x: iconRect.maxX + 3, y: iconRect.minY, width: t.width, height: t.height),
                    from: .zero, operation: .sourceOver, fraction: attention ? 1 : 0.6)
            }
            return true
        }
        image.isTemplate = !attention
        cache[key] = image
        return image
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return out
    }
}
