import AppKit
import ChiefStewCore
import SwiftUI

/// The menu-bar item: one fixed-width icon, never text (macOS hides menu-bar items that don't
/// fit, and a long branch name took the whole item with it). MenuBarExtra renders labels
/// monochrome, so the attention colour lives in the image itself.
///
///   idle         the ferry
///   in progress  the ferry + a small dot
///   needs you    an orange ferry + an orange dot
///   warning      + a small triangle (left-behind findings, or a repo it can't read)
public struct MenuBarLabel: View {
    var state: MenuBarState

    public init(state: MenuBarState) { self.state = state }

    public var body: some View {
        Image(nsImage: MenuBarIcon.image(attention: state.attention, busy: state.busy, warning: state.warning))
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "Chief Stew"
        if let title = state.title {
            text += ", \(title)"
        } else if !state.busy {
            text += state.loading ? ", checking" : ", nothing in flight"
        }
        if state.unreadable { text += ", a repo can't be read" } else if state.warning { text += ", something left behind" }
        return text
    }
}

public enum MenuBarIcon {
    static let symbol = "ferry"
    /// Always the same width, whatever the state, so the menu bar never reflows.
    static let size = NSSize(width: 22, height: 18)

    @MainActor public static func image(attention: Bool, busy: Bool, warning: Bool) -> NSImage {
        let key = "\(attention)-\(busy)-\(warning)"
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let base =
            NSImage(systemSymbolName: symbol, accessibilityDescription: "Chief Stew")?
            .withSymbolConfiguration(config) ?? NSImage()
        let triangle = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        let ink: NSColor = attention ? .systemOrange : .black
        let image = NSImage(size: size, flipped: false) { rect in
            // The ferry, left-aligned, vertically centred.
            let b = base.size
            let iconRect = NSRect(x: 0, y: (rect.height - b.height) / 2, width: b.width, height: b.height)
            tinted(base, ink).draw(in: iconRect)
            // A dot top-right: work in flight (orange when something needs you).
            if busy || attention {
                ink.setFill()
                let d: CGFloat = attention ? 6.5 : 5
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - d - 0.5, y: rect.maxY - d - 1, width: d, height: d)).fill()
            }
            // A triangle bottom-right: something left behind, or a repo it can't read.
            if warning, let triangle {
                let t = triangle.size
                // Cut a thin gap around it first, so it reads as a badge, not part of the hull.
                triangle.draw(
                    in: NSRect(x: rect.maxX - t.width - 1.2, y: -1.2, width: t.width + 2.4, height: t.height + 2.4),
                    from: .zero, operation: .destinationOut, fraction: 1)
                tinted(triangle, ink).draw(
                    in: NSRect(x: rect.maxX - t.width, y: 0, width: t.width, height: t.height),
                    from: .zero, operation: .sourceOver, fraction: attention ? 1 : 0.85)
            }
            return true
        }
        image.isTemplate = !attention  // monochrome states follow the menu bar's light/dark
        cache[key] = image
        return image
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
