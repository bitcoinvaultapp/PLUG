import SwiftUI

// MARK: - Color theme (used across app)

extension Color {
    static let bgDark = Color(red: 0.07, green: 0.07, blue: 0.11)
    static let cardDark = Color(red: 0.11, green: 0.11, blue: 0.16)
    static let btcOrange = Color(red: 0.97, green: 0.58, blue: 0.10)
    static let vaultYellow = Color(red: 0.93, green: 0.79, blue: 0.15)
    static let inheritancePurple = Color(red: 0.65, green: 0.40, blue: 0.90)
    static let poolTeal = Color(red: 0.20, green: 0.82, blue: 0.73)
    static let accentGreen = Color(red: 0.30, green: 0.85, blue: 0.40)
    static let dimText = Color(red: 0.45, green: 0.45, blue: 0.52)
}

struct HomeView: View {
    @StateObject private var vm = HomeVM()
    @EnvironmentObject var walletVM: WalletVM

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Custom header
                    headerBar

                    // Existing cards
                    balanceCard
                    networkStatsCard

                    // Bitcoin stats
                    halvingCard
                    supplyCard

                    if !vm.alerts.isEmpty {
                        alertsSection
                    }

                    // Daily tip
                    dailyTipCard

                    // Contracts summary
                    contractsSummary
                }
                .padding()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await vm.refresh()
                await walletVM.loadWallet()
                vm.updateBalance(walletVM.totalBalance)
            }
            .task {
                async let refreshTask: () = vm.refresh()
                async let walletTask: () = walletVM.loadWallet()
                _ = await (refreshTask, walletTask)
                vm.updateBalance(walletVM.totalBalance)
                vm.connectWebSocket()
            }
        }
    }

    // =====================================================================
    // MARK: - Header (replicated from screenshot)
    // =====================================================================

    private var headerBar: some View {
        PlugHeader(pageName: "Home")
    }

    // =====================================================================
    // MARK: - Balance Card (untouched)
    // =====================================================================

    private var balanceCard: some View {
        VStack(spacing: 12) {
            Text("Total Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(vm.totalBalance) sats")
                .font(.system(size: 32, weight: .bold, design: .monospaced))

            if vm.btcPrice > 0 {
                let btc = Double(vm.totalBalance) / 100_000_000
                Text(String(format: "%.8f BTC  |  $%.2f USD", btc, btc * vm.btcPrice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // =====================================================================
    // MARK: - Network Stats (untouched)
    // =====================================================================

    private var networkStatsCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Network")
                    .font(.headline)
                Spacer()
                Text(NetworkConfig.shared.networkName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(NetworkConfig.shared.isTestnet ? Color.orange : Color.green, in: Capsule())
                    .foregroundStyle(.white)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statItem(title: "Block", value: "\(vm.blockHeight)")
                statItem(title: "Fast Fee", value: vm.feeEstimate.map { "\($0.fastestFee) sat/vB" } ?? "—")
                statItem(title: "Economy Fee", value: vm.feeEstimate.map { "\($0.economyFee) sat/vB" } ?? "—")
                if let diff = vm.difficulty {
                    statItem(title: "Difficulty", value: String(format: "%.1f%%", diff.progressPercent))
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // =====================================================================
    // MARK: - Alerts (untouched)
    // =====================================================================

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alerts")
                .font(.headline)

            ForEach(vm.alerts) { alert in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(alert.message)
                        .font(.subheadline)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // =====================================================================
    // MARK: - Halving Countdown
    // =====================================================================

    private var halvingCard: some View {
        let currentBlock = vm.blockHeight
        let halvingInterval = 210_000
        let nextHalving = ((currentBlock / halvingInterval) + 1) * halvingInterval
        let blocksRemaining = nextHalving - currentBlock
        let progress = Double(currentBlock % halvingInterval) / Double(halvingInterval)
        let currentReward = 3.125 // BTC (post-2024 halving)
        let halvingNumber = (currentBlock / halvingInterval) + 1
        let estimatedDays = blocksRemaining * 10 / 60 / 24 // ~10 min per block

        return VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.btcOrange)
                        Text("Halving #\(halvingNumber)")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text("Block \(nextHalving)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(blocksRemaining)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.btcOrange)
                    Text("blocks left")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.btcOrange)
                        .frame(width: geo.size.width * progress, height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Label("\(currentReward) BTC/block", systemImage: "bitcoinsign.circle")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("~\(estimatedDays) days")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // =====================================================================
    // MARK: - Supply Stats
    // =====================================================================

    private var supplyCard: some View {
        let currentBlock = vm.blockHeight
        // Approximate circulating supply calculation
        let supply: Double = {
            var total: Double = 0
            var reward: Double = 50
            var blocks = 0
            while blocks < currentBlock {
                let epochEnd = blocks + 210_000
                let blocksInEpoch = min(currentBlock - blocks, 210_000)
                total += Double(blocksInEpoch) * reward
                blocks = epochEnd
                reward /= 2
            }
            return total
        }()
        let maxSupply: Double = 21_000_000
        let percentMined = supply / maxSupply * 100
        let inflationRate = (3.125 * 6 * 24 * 365) / supply * 100

        return VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.cyan)
                    Text("Supply")
                        .font(.system(size: 15, weight: .bold))
                }
                Spacer()
                Text(String(format: "%.1f%%", percentMined))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }

            // Supply bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.cyan)
                        .frame(width: geo.size.width * (supply / maxSupply), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f", supply))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("circulating")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    Text(String(format: "%.2f%%", inflationRate))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("inflation/yr")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("21 000 000")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("max supply")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // =====================================================================
    // MARK: - Daily Bitcoin Tip (from Mastering Bitcoin ch13)
    // =====================================================================

    private var dailyTipCard: some View {
        let tips = [
            ("lock.shield.fill", "Never reuse a Bitcoin address. Each address should be used only once for receiving.", Color.green),
            ("key.fill", "Your Ledger seed phrase is the master key. Store it offline, never digitally.", Color.btcOrange),
            ("eye.slash.fill", "Use coin control to avoid mixing KYC and non-KYC UTXOs in the same transaction.", Color.purple),
            ("checkmark.shield.fill", "Always verify the receive address on your Ledger screen before sending funds.", Color.blue),
            ("clock.fill", "Wait for at least 6 confirmations before considering a large payment final.", Color.orange),
            ("antenna.radiowaves.left.and.right", "Consider using Tor to hide your IP address when querying the blockchain.", Color.teal),
            ("exclamationmark.triangle.fill", "Dust outputs (< 546 sats) cost more in fees to spend than they're worth.", Color.yellow),
            ("arrow.triangle.2.circlepath", "CoinJoin combines multiple transactions for privacy. No trust required.", Color.purple),
            ("bitcoinsign.circle.fill", "Bitcoin's supply is capped at 21 million. No government can inflate it.", Color.btcOrange),
            ("doc.text.fill", "Label your transactions. Future you will thank present you.", Color.blue),
            ("person.2.fill", "Multisig requires M-of-N signatures. No single point of failure.", Color.teal),
            ("timer", "OP_CHECKLOCKTIMEVERIFY locks funds until a specific block height.", Color.orange),
        ]

        let dayIndex = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let tip = tips[dayIndex % tips.count]

        return HStack(spacing: 12) {
            Image(systemName: tip.0)
                .font(.system(size: 22))
                .foregroundStyle(tip.2)
                .frame(width: 44, height: 44)
                .background(tip.2.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text("Daily Tip")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(tip.1)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // =====================================================================
    // MARK: - Contracts Summary
    // =====================================================================
    // =====================================================================

    private var contractsSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Contracts")
                .font(.headline)

            // Vaults card
            if !vm.vaults.isEmpty {
                contractTypeCard(
                    icon: "lock.fill",
                    iconBg: Color.vaultYellow,
                    title: "Vaults",
                    count: vm.vaults.count,
                    totalSats: vm.vaultsBalance,
                    badges: vaultBadges
                ) {
                    ForEach(vm.vaults) { vault in
                        vaultRow(vault)
                    }
                }
            }

            // Inheritance card
            if !vm.inheritances.isEmpty {
                contractTypeCard(
                    icon: "shield.fill",
                    iconBg: Color.inheritancePurple,
                    title: "Inheritance",
                    count: vm.inheritances.count,
                    totalSats: vm.inheritanceBalance,
                    badges: [("CSV", Color.inheritancePurple)]
                ) {
                    ForEach(vm.inheritances) { inheritance in
                        inheritanceRow(inheritance)
                    }
                }
            }

            // Pools card
            if !vm.pools.isEmpty {
                contractTypeCard(
                    icon: "person.2.fill",
                    iconBg: Color.poolTeal,
                    title: "Pools",
                    count: vm.pools.count,
                    totalSats: vm.poolsBalance,
                    badges: [("MULTI", Color.poolTeal)]
                ) {
                    ForEach(vm.pools) { pool in
                        poolRow(pool)
                    }
                }
            }

            // Nothing at all — no "No contracts" message, just hide
        }
    }

    // MARK: - Vault badges

    private var vaultBadges: [(String, Color)] {
        var badges: [(String, Color)] = []
        let ready = vm.readyVaultsCount
        if ready > 0 {
            badges.append(("\(ready) READY", Color.accentGreen))
        }
        badges.append(("CLTV", Color.btcOrange))
        return badges
    }

    // MARK: - Generic contract type card

    private func contractTypeCard<Content: View>(
        icon: String,
        iconBg: Color,
        title: String,
        count: Int,
        totalSats: UInt64,
        badges: [(String, Color)],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack(spacing: 12) {
                // Icon badge
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(iconBg)
                    .frame(width: 44, height: 44)
                    .background(iconBg.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))

                // Title + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                    Text("\(count) active \u{00B7} \(HomeVM.formatSats(totalSats)) sats")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Badge chips
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    Text(badge.0)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(badge.1.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(badge.1)
                }
            }

            // Divider
            Rectangle()
                .fill(.secondary.opacity(0.2))
                .frame(height: 0.5)
                .padding(.vertical, 10)

            // Contract rows
            content()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Vault row

    private func vaultRow(_ vault: Contract) -> some View {
        HStack {
            Circle()
                .fill(vm.isVaultUnlocked(vault) ? Color.accentGreen : Color.btcOrange)
                .frame(width: 6, height: 6)
            Text(vault.name)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if vm.isVaultUnlocked(vault) {
                Text("Unlocked")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentGreen)
            } else {
                HStack(spacing: 4) {
                    Text("Locked")
                        .foregroundStyle(Color.btcOrange)
                    Text("\u{00B7}")
                        .foregroundStyle(.secondary)
                    Text(vm.vaultTimeRemaining(vault))
                        .foregroundStyle(Color.btcOrange)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Inheritance row

    private func inheritanceRow(_ inheritance: Contract) -> some View {
        HStack {
            Circle()
                .fill(Color.accentGreen)
                .frame(width: 6, height: 6)
            Text(inheritance.name)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            HStack(spacing: 4) {
                Text("Active")
                    .foregroundStyle(Color.accentGreen)
                Text("\u{00B7}")
                    .foregroundStyle(.secondary)
                Text(vm.inheritanceWindow(inheritance))
                    .foregroundStyle(Color.accentGreen)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.vertical, 3)
    }

    // MARK: - Pool row

    private func poolRow(_ pool: Contract) -> some View {
        HStack {
            Circle()
                .fill(Color.btcOrange)
                .frame(width: 6, height: 6)
            Text(pool.name)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if let m = pool.multisigM, let n = pool.multisigPubkeys?.count {
                HStack(spacing: 3) {
                    Text("\(m)/\(n)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.poolTeal)
                    ForEach(0..<n, id: \.self) { i in
                        Circle()
                            .fill(i < m ? Color.poolTeal : Color.dimText)
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Bitcoin Plug ₿ Logo (vector, no background, 3D)

struct BitcoinPlugLogo: View {
    var body: some View {
        ZStack {
            // Shadow
            BitcoinBShape()
                .fill(Color(red: 0.55, green: 0.32, blue: 0.03))
                .offset(x: 0.6, y: 1.0)
            // Body gradient
            BitcoinBShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.75, blue: 0.28),
                            Color(red: 0.969, green: 0.576, blue: 0.102),
                            Color(red: 0.78, green: 0.42, blue: 0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            // Highlight
            BitcoinBShape()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.3), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
    }
}

/// The ₿ shape with two vertical prongs — drawn as a Path
struct BitcoinBShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()

        // Two vertical prongs on top
        let prongW = w * 0.09
        let prongH = h * 0.12

        // Left prong
        p.addRect(CGRect(x: w * 0.30, y: 0, width: prongW, height: prongH))
        // Right prong
        p.addRect(CGRect(x: w * 0.55, y: 0, width: prongW, height: prongH))

        // Two vertical prongs on bottom
        p.addRect(CGRect(x: w * 0.30, y: h - prongH, width: prongW, height: prongH))
        p.addRect(CGRect(x: w * 0.55, y: h - prongH, width: prongW, height: prongH))

        // Vertical bar (left side of B)
        let barX = w * 0.18
        let barW = w * 0.14
        let barTop = h * 0.10
        let barBot = h * 0.90
        p.addRect(CGRect(x: barX, y: barTop, width: barW, height: barBot - barTop))

        // Upper bump of B
        let upperTop = h * 0.10
        let upperBot = h * 0.48
        let upperRight = w * 0.78

        p.move(to: CGPoint(x: barX + barW, y: upperTop))
        p.addLine(to: CGPoint(x: w * 0.62, y: upperTop))
        p.addQuadCurve(
            to: CGPoint(x: w * 0.62, y: upperBot),
            control: CGPoint(x: upperRight, y: (upperTop + upperBot) / 2)
        )
        p.addLine(to: CGPoint(x: barX + barW, y: upperBot))
        p.closeSubpath()

        // Lower bump of B (wider)
        let lowerTop = h * 0.52
        let lowerBot = h * 0.90
        let lowerRight = w * 0.85

        p.move(to: CGPoint(x: barX + barW, y: lowerTop))
        p.addLine(to: CGPoint(x: w * 0.65, y: lowerTop))
        p.addQuadCurve(
            to: CGPoint(x: w * 0.65, y: lowerBot),
            control: CGPoint(x: lowerRight, y: (lowerTop + lowerBot) / 2)
        )
        p.addLine(to: CGPoint(x: barX + barW, y: lowerBot))
        p.closeSubpath()

        // Horizontal bars
        let hBarH = h * 0.06
        p.addRect(CGRect(x: barX, y: upperTop, width: w * 0.50, height: hBarH))
        p.addRect(CGRect(x: barX, y: upperBot - hBarH / 2, width: w * 0.48, height: hBarH))
        p.addRect(CGRect(x: barX, y: lowerBot - hBarH, width: w * 0.52, height: hBarH))

        return p
    }
}
