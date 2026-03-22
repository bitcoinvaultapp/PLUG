import SwiftUI

struct UTXOManagerPage: View {
    let utxos: [UTXO]
    let walletAddresses: [WalletAddress]
    let transactions: [Transaction]

    @ObservedObject private var frozenStore = FrozenUTXOStore.shared
    @State private var filter: UTXOFilter = .all
    @State private var sortOrder: UTXOSort = .amountHigh
    @State private var copiedOutpoint = ""

    enum UTXOFilter: String, CaseIterable {
        case all = "All"
        case frozen = "Frozen"
        case dust = "Dust"
        case exposed = "Exposed"
        case unconfirmed = "Pending"
    }

    enum UTXOSort: String, CaseIterable {
        case amountHigh = "Amount ↓"
        case amountLow = "Amount ↑"
        case newest = "Newest"
        case oldest = "Oldest"
    }

    private var filtered: [UTXO] {
        var list = utxos
        switch filter {
        case .all: break
        case .frozen: list = list.filter { FrozenUTXOStore.shared.isFrozen(outpoint: $0.outpoint) }
        case .dust: list = list.filter { $0.value < 546 }
        case .exposed:
            let spent = spentFromAddresses
            list = list.filter { spent.contains($0.address) }
        case .unconfirmed: list = list.filter { !$0.status.confirmed }
        }
        switch sortOrder {
        case .amountHigh: list.sort { $0.value > $1.value }
        case .amountLow: list.sort { $0.value < $1.value }
        case .newest: list.sort { ($0.status.blockHeight ?? Int.max) > ($1.status.blockHeight ?? Int.max) }
        case .oldest: list.sort { ($0.status.blockHeight ?? 0) < ($1.status.blockHeight ?? 0) }
        }
        return list
    }

    private var spentFromAddresses: Set<String> {
        let known = Set(walletAddresses.map(\.address))
        var spent = Set<String>()
        for tx in transactions {
            for input in tx.vin {
                if let a = input.prevout?.scriptpubkeyAddress, known.contains(a) {
                    spent.insert(a)
                }
            }
        }
        return spent
    }

    private var frozenTotal: UInt64 {
        utxos.filter { FrozenUTXOStore.shared.isFrozen(outpoint: $0.outpoint) }.reduce(0) { $0 + $1.value }
    }

    private var dustCount: Int {
        utxos.filter { $0.value < 546 }.count
    }

    var body: some View {
        List {
            // Summary
            summarySection

            // Filters
            filterSection

            // UTXO list
            utxoListSection
        }
        .listStyle(.plain)
        .navigationTitle("UTXOs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                sortMenu
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            HStack(spacing: 16) {
                statCell("\(utxos.count)", label: "UTXOs")
                statCell(BalanceUnit.format(frozenTotal), label: "Frozen")
                statCell("\(dustCount)", label: "Dust")
            }
            .listRowBackground(Color.clear)
        }
    }

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(UTXOFilter.allCases, id: \.self) { f in
                        filterChip(f)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    private var utxoListSection: some View {
        Section {
            if filtered.isEmpty {
                HStack {
                    Spacer()
                    Text("No UTXOs match filter")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 20)
            } else {
                ForEach(filtered) { utxo in
                    utxoRow(utxo)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            freezeButton(utxo)
                        }
                        .swipeActions(edge: .leading) {
                            copyButton(utxo)
                        }
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(UTXOSort.allCases, id: \.self) { s in
                Button {
                    sortOrder = s
                } label: {
                    HStack {
                        Text(s.rawValue)
                        if sortOrder == s {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 16))
        }
    }

    // MARK: - Row

    private func utxoRow(_ utxo: UTXO) -> some View {
        let frozen = FrozenUTXOStore.shared.isFrozen(outpoint: utxo.outpoint)
        let addr = walletAddresses.first { $0.address == utxo.address }
        let isChange = addr?.isChange ?? false
        let index = addr?.index

        return HStack(spacing: 10) {
            Circle()
                .fill(utxo.status.confirmed ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            if let idx = index {
                Text(isChange ? "C#\(idx)" : "#\(idx)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(isChange ? Color.gray : Color.purple.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(utxo.txid.prefix(10)) + ":\(utxo.vout)")
                    .font(.system(size: 11, design: .monospaced))
                Text(String(utxo.address.prefix(10)) + "..." + String(utxo.address.suffix(4)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                if frozen {
                    Image(systemName: "snowflake")
                        .font(.system(size: 9))
                        .foregroundStyle(.cyan)
                }
                if utxo.value < 546 {
                    Text("DUST")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)
                }
            }

            Text(BalanceUnit.format(utxo.value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(frozen ? .secondary : .primary)
        }
        .padding(.vertical, 3)
        .opacity(frozen ? 0.5 : 1)
    }

    // MARK: - Components

    private func statCell(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func filterChip(_ f: UTXOFilter) -> some View {
        Button {
            filter = f
        } label: {
            Text(f.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(filter == f ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(filter == f ? Color.purple : Color(.systemGray5).opacity(0.3), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func freezeButton(_ utxo: UTXO) -> some View {
        let frozen = FrozenUTXOStore.shared.isFrozen(outpoint: utxo.outpoint)
        return Button {
            if FrozenUTXOStore.shared.isFrozen(outpoint: utxo.outpoint) {
                FrozenUTXOStore.shared.unfreeze(outpoint: utxo.outpoint)
            } else {
                FrozenUTXOStore.shared.freeze(outpoint: utxo.outpoint)
            }
        } label: {
            Label(frozen ? "Unfreeze" : "Freeze", systemImage: frozen ? "flame" : "snowflake")
        }
        .tint(frozen ? .orange : .cyan)
    }

    private func copyButton(_ utxo: UTXO) -> some View {
        Button {
            UIPasteboard.general.string = utxo.outpoint
            copiedOutpoint = utxo.outpoint
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedOutpoint = "" }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .tint(.blue)
    }
}
