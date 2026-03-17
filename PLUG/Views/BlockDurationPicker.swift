import SwiftUI

/// Shared duration picker for all contract types that use block-based timelocks.
/// Replaces raw block height inputs with human-friendly duration presets + calendar dates.
struct BlockDurationPicker: View {

    enum Mode {
        case absoluteCLTV  // Tirelire, HTLC, Channel: target = currentHeight + blocks
        case relativeCSV   // Heritage: target = blocks (relative delay)
    }

    @Binding var value: String       // The raw string bound to the VM (block height or block count)
    let currentBlockHeight: Int
    let mode: Mode
    let presets: [(label: String, blocks: Int)]

    var body: some View {
        Section {
            TextField(mode == .absoluteCLTV ? "Ex: \(currentBlockHeight + 144)" : "Ex: 1008", text: $value)
                .keyboardType(.numberPad)

            if mode == .absoluteCLTV {
                Text("Current block: \(currentBlockHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Preset duration buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.label) { label, blocks in
                        Button(label) {
                            if mode == .absoluteCLTV {
                                value = "\(currentBlockHeight + blocks)"
                            } else {
                                value = "\(blocks)"
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption2)
                    }
                }
            }

            // Validation + time display
            if let parsed = Int(value) {
                let blocks: Int = mode == .absoluteCLTV ? parsed - currentBlockHeight : parsed
                if blocks <= 0 && mode == .absoluteCLTV {
                    Label("Must be greater than current block (\(currentBlockHeight))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if blocks > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Self.blocksToHumanTime(blocks: blocks)) (\(blocks) blocs)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Self.blocksToDateString(blocks: blocks))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text(mode == .absoluteCLTV ? "Lock duration" : "Inactivity delay (CSV)")
        }
    }

    // MARK: - Static Utilities (reusable project-wide)

    /// Convert block count to human-readable duration string
    static func blocksToHumanTime(blocks: Int) -> String {
        let totalMinutes = blocks * 10
        let totalHours = totalMinutes / 60
        let totalDays = totalHours / 24

        if totalDays >= 365 {
            let years = totalDays / 365
            let remainingDays = totalDays % 365
            let months = remainingDays / 30
            return months > 0 ? "~\(years)a \(months)m" : "~\(years)a"
        } else if totalDays >= 30 {
            let months = totalDays / 30
            let days = totalDays % 30
            return days > 0 ? "~\(months)m \(days)j" : "~\(months)m"
        } else if totalHours >= 24 {
            let days = totalHours / 24
            let hours = totalHours % 24
            return hours > 0 ? "~\(days)j \(hours)h" : "~\(days)j"
        } else if totalHours > 0 {
            let mins = totalMinutes % 60
            return mins > 0 ? "~\(totalHours)h \(mins)min" : "~\(totalHours)h"
        } else {
            return "~\(totalMinutes)min"
        }
    }

    /// Convert block count to estimated calendar date string
    static func blocksToDateString(blocks: Int) -> String {
        let date = Date.now.addingTimeInterval(TimeInterval(blocks * 10 * 60))
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        return "~\(formatter.string(from: date))"
    }

    /// Convert block count to estimated Date
    static func blocksToDate(blocks: Int) -> Date {
        Date.now.addingTimeInterval(TimeInterval(blocks * 10 * 60))
    }
}
