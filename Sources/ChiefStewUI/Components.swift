import ChiefStewCore
import SwiftUI

enum Palette {
    static let attention = Color(nsColor: .systemOrange)
    static let running = Color(nsColor: .systemGreen)
    static let problem = Color(nsColor: .systemRed)
    static let dot = Color(nsColor: .secondaryLabelColor)
}

/// The 7 (full lane) or 4 (fast lane) phase dots.
struct PhaseDotsView: View {
    var dots: [PhaseDot]
    var dimmed = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                dotView(dot).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(
            "\(dots.filter { $0 == .done }.count) of \(dots.count) phases done")
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
            .padding(.horizontal, 9)
            .padding(.vertical, 2.5)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(primary ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
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
            let size = view.sizeThatFits(.unspecified)
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
            let size = view.sizeThatFits(.unspecified)
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
