import SwiftUI

// MARK: - Hex Grid View (main contract display)

struct HexGridView: View {
    @ObservedObject var vm: ContractBubbleVM
    var onSelect: ((Contract) -> Void)?
    @State private var appeared = false

    private let hexSize: CGFloat = 75 // "radius" of each hex

    var body: some View {
        GeometryReader { geo in
            let positions = hexPositions(count: vm.nodes.count, in: geo.size)

            ZStack {
                ForEach(Array(vm.nodes.enumerated()), id: \.element.id) { index, node in
                    if index < positions.count {
                        hexTile(node: node)
                            .position(positions[index])
                            .scaleEffect(appeared ? 1.0 : 0.01)
                            .opacity(appeared ? 1.0 : 0)
                            .animation(
                                .spring(response: 0.45, dampingFraction: 0.75)
                                    .delay(Double(index) * 0.07),
                                value: appeared
                            )
                            .onTapGesture {
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                                onSelect?(node.contract)
                            }
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    appeared = true
                }
            }
            .onChange(of: vm.nodes.count) { _ in
                appeared = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Hex Layout

    /// Compute honeycomb positions centered in the available space.
    private func hexPositions(count: Int, in size: CGSize) -> [CGPoint] {
        guard count > 0 else { return [] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let h = hexSize * 0.88 // vertical spacing factor
        let w = hexSize * 1.02 // horizontal spacing factor

        if count == 1 {
            return [center]
        }

        // Spiral hex placement: center, then rings
        var positions: [CGPoint] = [center]

        // Ring 1: 6 neighbors
        let ring1Offsets: [(CGFloat, CGFloat)] = [
            (0, -2 * h),                         // top
            (w * 1.5, -h),                        // top-right
            (w * 1.5, h),                         // bottom-right
            (0, 2 * h),                           // bottom
            (-w * 1.5, h),                        // bottom-left
            (-w * 1.5, -h),                       // top-left
        ]

        for offset in ring1Offsets {
            if positions.count >= count { break }
            positions.append(CGPoint(x: center.x + offset.0, y: center.y + offset.1))
        }

        // Ring 2 (12 positions) if needed
        let ring2Offsets: [(CGFloat, CGFloat)] = [
            (0, -4 * h),
            (w * 1.5, -3 * h),
            (w * 3.0, -2 * h),
            (w * 3.0, 0),
            (w * 3.0, 2 * h),
            (w * 1.5, 3 * h),
            (0, 4 * h),
            (-w * 1.5, 3 * h),
            (-w * 3.0, 2 * h),
            (-w * 3.0, 0),
            (-w * 3.0, -2 * h),
            (-w * 1.5, -3 * h),
        ]

        for offset in ring2Offsets {
            if positions.count >= count { break }
            positions.append(CGPoint(x: center.x + offset.0, y: center.y + offset.1))
        }

        return Array(positions.prefix(count))
    }

    // MARK: - Hex Tile

    private func hexTile(node: ContractNode) -> some View {
        let color = contractTypeColor(node.contract.type)
        let isEmpty = node.balance == 0

        return ZStack {
            // Hex shape — frosted glass
            HexShape()
                .fill(.ultraThinMaterial)
                .frame(width: hexSize * 2, height: hexSize * 1.74)
                .shadow(color: color.opacity(0.25), radius: 10, x: 0, y: 4)

            // Colored top edge
            HexShape()
                .stroke(
                    LinearGradient(
                        colors: [color.opacity(isEmpty ? 0.25 : 0.6), color.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
                .frame(width: hexSize * 2, height: hexSize * 1.74)

            // Content
            VStack(spacing: 5) {
                Image(systemName: contractTypeIcon(node.contract.type))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)

                Text(node.contract.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if node.balance > 0 {
                    Text(BalanceUnit.format(node.balance))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: hexSize * 1.4)
        }
    }

    // MARK: - Helpers

    private func contractTypeColor(_ type: ContractType) -> Color {
        switch type {
        case .vault: return .orange
        case .inheritance: return .purple
        case .pool: return .blue
        case .htlc: return .teal
        case .channel: return .green
        }
    }

    private func contractTypeIcon(_ type: ContractType) -> String {
        switch type {
        case .vault: return "lock.fill"
        case .inheritance: return "person.2.fill"
        case .pool: return "person.3.fill"
        case .htlc: return "arrow.left.arrow.right"
        case .channel: return "bolt.fill"
        }
    }
}

// MARK: - Hex Shape

struct HexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX

        var path = Path()
        // Flat-top hexagon
        path.move(to: CGPoint(x: cx - w / 4, y: 0))
        path.addLine(to: CGPoint(x: cx + w / 4, y: 0))
        path.addLine(to: CGPoint(x: w, y: h / 2))
        path.addLine(to: CGPoint(x: cx + w / 4, y: h))
        path.addLine(to: CGPoint(x: cx - w / 4, y: h))
        path.addLine(to: CGPoint(x: 0, y: h / 2))
        path.closeSubpath()
        return path
    }
}

