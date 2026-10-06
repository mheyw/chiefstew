import AppKit
import ChiefStewCore
import SwiftUI

/// System colours are for dots, icons and shapes. Text uses the `…Text` colours: as text on a
/// light window, systemOrange and systemGreen are under 2:1.
public enum Palette {
    public static let attention = Color(nsColor: .systemOrange)
    public static let running = Color(nsColor: .systemGreen)
    public static let problem = Color(nsColor: .systemRed)
    public static let dot = Color(nsColor: .secondaryLabelColor)

    /// 5.2:1 on a light window, 6.2:1 dark.
    public static let attentionText = adaptive(light: 0xB03A00, dark: .systemOrange)
    /// 5.1:1 light, 4.6:1 dark.
    public static let problemText = adaptive(light: 0xC4161C, dark: NSColor(rgb: 0xFF6961))
    /// 5.4:1 light, 6.7:1 dark.
    public static let okText = adaptive(light: 0x1A6E2C, dark: .systemGreen)

    private static func adaptive(light: Int, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : NSColor(rgb: light)
        })
    }
}

extension NSColor {
    fileprivate convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// The 7 (full lane) or 4 (fast lane) phase dots.
struct PhaseDotsView: View {
    var dots: [PhaseDot]
    var dimmed = false
    /// One line per phase (`BuildCard.phaseLines`), read by VoiceOver.
    var detail: [String] = []
    /// The dot under the pointer. The row shows that phase's line in place of its label: system
    /// tooltips don't appear in a menu-bar panel, and a line swapped in place never jumps.
    var hovered: Binding<Int?>?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(dots.enumerated()), id: \.offset) { i, dot in
                dotView(dot).frame(width: 7, height: 7)
                    // A bigger target than the dot, filling the gap to the next one.
                    .padding(.horizontal, 1.5).padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard let hovered else { return }
                        if inside { hovered.wrappedValue = i } else if hovered.wrappedValue == i { hovered.wrappedValue = nil }
                    }
            }
        }
        .padding(.horizontal, -1.5)
        .accessibilityElement()
        .accessibilityLabel(
            "\(dots.filter { $0 == .done }.count) of \(dots.count) phases done")
        .accessibilityValue(detail.joined(separator: ", "))
    }

    @ViewBuilder private func dotView(_ dot: PhaseDot) -> some View {
        let tint = dimmed ? Palette.dot.opacity(0.6) : Palette.dot
        switch dot {
        case .done: Circle().fill(tint)
        case .pending: Circle().strokeBorder(tint, lineWidth: 1.2)
        case .waiting: Circle().fill(dimmed ? tint : Palette.attention)
        case .active:
            Circle().strokeBorder(tint, lineWidth: 1.2)
                .overlay(
                    Circle().fill(tint).mask(
                        HStack(spacing: 0) {
                            Rectangle()
                            Color.clear
                        }))
        }
    }
}

/// One line, cut short; rest the pointer on it and it shows in full. System tooltips don't
/// appear in a menu-bar panel. The wait means a pointer passing over on its way to the buttons
/// below doesn't push them away; leaving collapses it at once.
struct ExpandingLine: View {
    var text: String
    static let delay: Duration = .milliseconds(500)
    @State private var expanded = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Text(text).lineLimit(expanded ? nil : 1).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .onHover { inside in
                pending?.cancel()
                guard inside else {
                    expanded = false
                    return
                }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: Self.delay)
                    if !Task.isCancelled { expanded = true }
                }
            }
            .onDisappear { pending?.cancel() }
    }
}

struct TaskBar: View {
    var tasks: TaskCount

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Palette.running)
                    .frame(
                        width: geo.size.width * CGFloat(tasks.done) / CGFloat(max(tasks.total, 1)))
            }
        }
        .frame(width: 90, height: 4)
    }
}

/// A small button drawn in SwiftUI (not AppKit), so it also renders in offscreen snapshots.
struct PillButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.vertical, 2.5)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(primary ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    // Darkened so white text clears 4.5:1 on the default blue; a light user accent
                    // (yellow, orange, green) still doesn't.
                    .overlay(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(primary ? 0.2 : 0)))
                    .shadow(color: .black.opacity(primary ? 0 : 0.12), radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(primary ? 0 : 0.18), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct SectionTitle: View {
    var text: String
    var color: Color = .secondary
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased()).kerning(0.5)
            Spacer()
            if let trailing { Text(trailing).textCase(nil) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
    }
}

/// Wrapping row of buttons.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            if x > 0 && x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A status line in Settings and the wizard: the icon carries the colour, the text stays readable.
public struct StatusLabel: View {
    var text: String
    var symbol: String
    var tint: Color

    public init(_ text: String, systemImage: String, tint: Color) {
        self.text = text
        self.symbol = systemImage
        self.tint = tint
    }

    public var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
    }
}
