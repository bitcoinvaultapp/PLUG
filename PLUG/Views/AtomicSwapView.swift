import SwiftUI
import CoreImage.CIFilterBuiltins

struct AtomicSwapView: View {
    @StateObject private var vm = AtomicSwapVM()
    @State private var showScanner = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Progress stepper
                progressStepper

                // Role selection or active flow
                if vm.step == .setup {
                    if vm.role == .initiator && vm.decodedOffer == nil {
                        roleSelector
                    }

                    if vm.role == .initiator {
                        exchangeCard
                        initiatorSetupFields
                    } else {
                        responderImport
                    }
                } else {
                    activeSwapView
                }

                // Error
                if let error = vm.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding()
        }
        .navigationTitle("P2P Swap")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadBlockHeight() }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { value in
                    vm.offerString = value
                    showScanner = false
                    vm.decodeOffer()
                    vm.role = .responder
                }
                .navigationTitle("Scan Offer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
        }
    }

    // MARK: - Progress Stepper

    private var progressStepper: some View {
        let steps = ["Setup", "Fund", "Verify", "Claim", "Done"]
        let currentIndex: Int = {
            switch vm.step {
            case .setup: return 0
            case .created: return 1
            case .waitingCounterparty: return 2
            case .funded, .claiming: return 3
            case .complete: return 4
            }
        }()

        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                VStack(spacing: 4) {
                    Circle()
                        .fill(index <= currentIndex ? Color.cyan : Color(.systemGray4))
                        .frame(width: 8, height: 8)
                    Text(label)
                        .font(.system(size: 8, weight: index == currentIndex ? .bold : .regular))
                        .foregroundStyle(index <= currentIndex ? .primary : .tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Hero + Role Selector

    private var roleSelector: some View {
        VStack(spacing: 16) {
            // Hero explanation
            VStack(spacing: 8) {
                Image(systemName: "person.2.badge.gearshape.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.cyan, .cyan.opacity(0.5))
                Text("Swap UTXOs trustlessly with another person. No exchange, no KYC, no intermediary.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 8)

            // Role cards
            HStack(spacing: 12) {
                roleCard(
                    icon: "plus.circle.fill",
                    title: "Start a Swap",
                    desc: "Create an offer",
                    isSelected: vm.role == .initiator
                ) {
                    vm.role = .initiator
                }

                roleCard(
                    icon: "qrcode.viewfinder",
                    title: "Join a Swap",
                    desc: "Scan an offer",
                    isSelected: vm.role == .responder
                ) {
                    vm.role = .responder
                }
            }
        }
    }

    private func roleCard(icon: String, title: String, desc: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? .cyan : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.cyan.opacity(0.4) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Exchange Card (hero element)

    private var exchangeCard: some View {
        VStack(spacing: 0) {
            // You send
            amountRow(
                label: "You send",
                amount: $vm.myAmount,
                asset: "BTC",
                color: .orange
            )

            // Swap arrow divider
            ZStack {
                Divider()
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.cyan)
                    .frame(width: 28, height: 28)
                    .background(Color(.systemBackground), in: Circle())
                    .overlay(Circle().strokeBorder(Color(.systemGray4), lineWidth: 0.5))
            }

            // You receive
            amountRow(
                label: "You receive",
                amount: $vm.requestedAmount,
                asset: "BTC",
                color: .green
            )
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func amountRow(label: String, amount: Binding<String>, asset: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack {
                TextField("0", text: amount)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .keyboardType(.numberPad)
                    .foregroundStyle(.primary)

                Spacer()

                Text(asset)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(color.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Initiator Setup Fields

    private var initiatorSetupFields: some View {
        VStack(spacing: 16) {
            // Counterparty key
            VStack(alignment: .leading, spacing: 6) {
                Text("Counterparty")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("xpub / tpub or pubkey hex", text: $vm.counterpartyXpub)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            // Name
            VStack(alignment: .leading, spacing: 6) {
                Text("Swap Name")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Privacy swap", text: $vm.name)
                    .font(.system(size: 13))
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            // Timeout + Key Index (compact)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Timeout (block)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("\(vm.currentBlockHeight + 144)", text: $vm.timeoutBlocks)
                        .font(.system(size: 13, design: .monospaced))
                        .keyboardType(.numberPad)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Key Index")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Stepper(value: $vm.keyIndex, in: 0...19) {
                        Text("#\(vm.keyIndex)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            // Timeout presets
            HStack(spacing: 8) {
                timeoutPreset("12h", blocks: 72)
                timeoutPreset("1d", blocks: 144)
                timeoutPreset("2d", blocks: 288)
                timeoutPreset("1w", blocks: 1008)
            }

            // Create button
            Button {
                Task { await vm.createInitiatorHTLC() }
            } label: {
                HStack {
                    if vm.isLoading {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 4)
                    }
                    Text("Create Swap Offer")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    canCreateOffer ? Color.cyan : Color(.systemGray3),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canCreateOffer || vm.isLoading)
        }
    }

    private var canCreateOffer: Bool {
        !vm.name.isEmpty && !vm.counterpartyXpub.isEmpty && !vm.timeoutBlocks.isEmpty &&
        (Int(vm.timeoutBlocks) ?? 0) > vm.currentBlockHeight
    }

    private func timeoutPreset(_ label: String, blocks: Int) -> some View {
        Button {
            vm.timeoutBlocks = "\(vm.currentBlockHeight + blocks)"
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(vm.timeoutBlocks == "\(vm.currentBlockHeight + blocks)" ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    vm.timeoutBlocks == "\(vm.currentBlockHeight + blocks)" ? Color.cyan : Color(.systemGray5),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Responder Import

    private var responderImport: some View {
        VStack(spacing: 16) {
            // Scan or paste
            VStack(spacing: 12) {
                Button {
                    showScanner = true
                } label: {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 18))
                        Text("Scan QR Code")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.cyan, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Text("or paste offer below")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                TextEditor(text: $vm.offerString)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 70)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Button("Decode Offer") {
                    vm.decodeOffer()
                }
                .font(.system(size: 13, weight: .medium))
                .disabled(vm.offerString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Decoded offer details
            if let offer = vm.decodedOffer {
                offerDetailsCard(offer)

                // Key index
                HStack {
                    Text("Your Key Index")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(value: $vm.keyIndex, in: 0...19) {
                        Text("#\(vm.keyIndex)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                // Accept button
                Button {
                    Task { await vm.createResponderHTLC() }
                } label: {
                    HStack {
                        if vm.isLoading {
                            ProgressView().tint(.white).padding(.trailing, 4)
                        }
                        Text("Accept & Create HTLC")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.cyan, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.isLoading)
            }
        }
    }

    private func offerDetailsCard(_ offer: SwapOffer) -> some View {
        VStack(spacing: 12) {
            // Exchange preview
            HStack {
                VStack(spacing: 2) {
                    Text("They send")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(BalanceUnit.format(offer.initiatorAmount))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.cyan)

                VStack(spacing: 2) {
                    Text("You send")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(BalanceUnit.format(offer.requestedAmount))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Details
            VStack(spacing: 6) {
                detailRow("Network", value: offer.network)
                detailRow("Initiator Timeout", value: "Block \(offer.initiatorTimeout)")
                detailRow("Your Timeout", value: "Block \(offer.suggestedTimeout)")
                detailRow("Hash Lock", value: String(offer.hashLock.prefix(16)) + "...")
            }

            // Verify funding
            Button {
                Task { await vm.verifyInitiatorFunding() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text(vm.counterpartyFundingStatus.isEmpty ? "Verify Funding" : vm.counterpartyFundingStatus)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(vm.counterpartyFundingStatus.hasPrefix("Funded") ? .green : .cyan)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Active Swap View (post-setup)

    @ViewBuilder
    private var activeSwapView: some View {
        switch vm.step {
        case .setup:
            EmptyView()
        case .created:
            createdView
        case .waitingCounterparty:
            monitoringView
        case .funded, .claiming:
            claimView
        case .complete:
            completeView
        }
    }

    // MARK: - Created (show QR / address)

    private var createdView: some View {
        VStack(spacing: 16) {
            // Success header
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                Text(vm.role == .initiator ? "Swap Offer Created" : "HTLC Created")
                    .font(.system(size: 16, weight: .semibold))
            }

            if let contract = vm.myContract {
                // Address card
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your HTLC Address")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(contract.address)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = contract.address
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Address")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.cyan)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            // QR code (initiator only)
            if vm.role == .initiator && !vm.swapOfferEncoded.isEmpty {
                VStack(spacing: 8) {
                    Text("Share with counterparty")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if let qr = generateQRCode(from: vm.swapOfferEncoded) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        secureCopy(vm.swapOfferEncoded)
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Offer")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.cyan)
                    }
                }
            }

            // Counterparty address input (initiator)
            if vm.role == .initiator {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Counterparty's HTLC Address")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Paste their address", text: $vm.counterpartyAddress)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            // Next button
            Button {
                vm.step = .waitingCounterparty
                vm.startPolling()
            } label: {
                Text("Monitor Swap")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.cyan, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(vm.role == .initiator && vm.counterpartyAddress.isEmpty)
        }
    }

    // MARK: - Monitoring

    private var monitoringView: some View {
        VStack(spacing: 16) {
            // Live status
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.cyan)
                    Text("Monitoring")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                }

                VStack(spacing: 8) {
                    statusRow("Your HTLC", status: vm.myFundingStatus.isEmpty ? "Checking..." : vm.myFundingStatus)
                    statusRow("Counterparty", status: vm.counterpartyFundingStatus.isEmpty ? "Checking..." : vm.counterpartyFundingStatus)

                    if vm.role == .responder && !vm.extractedPreimage.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.green)
                            Text("Preimage detected!")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

            // Claim button
            let canClaim = vm.role == .initiator ?
                vm.counterpartyFundingStatus.hasPrefix("Funded") :
                !vm.extractedPreimage.isEmpty

            Button {
                vm.step = .claiming
                vm.stopPolling()
            } label: {
                Text(vm.role == .initiator ? "Claim Counterparty's BTC" : "Claim with Preimage")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canClaim ? Color.green : Color(.systemGray3), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!canClaim)
        }
    }

    private func statusRow(_ label: String, status: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(status.hasPrefix("Funded") ? .green : .orange)
        }
    }

    // MARK: - Claim

    private var claimView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                Text("Ready to Claim")
                    .font(.system(size: 16, weight: .semibold))
            }

            // Preimage display
            if let contract = vm.myContract {
                let preimage = vm.role == .initiator ?
                    (KeychainStore.shared.loadString(forKey: "htlc_preimage_\(contract.id)") ?? "N/A") :
                    vm.extractedPreimage

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preimage")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(preimage)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)

                    Button {
                        secureCopy(preimage)
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Preimage")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.cyan)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            Text("Use the HTLC section in Contracts to claim with this preimage.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if var contract = vm.myContract {
                    contract.swapState = "completed"
                    ContractStore.shared.update(contract)
                }
                vm.step = .complete
                vm.stopPolling()
            } label: {
                Text("Mark as Complete")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Complete

    private var completeView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Swap Complete")
                    .font(.system(size: 18, weight: .bold))
                Text("Both HTLCs settled trustlessly.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)

            Button {
                vm.reset()
            } label: {
                Text("New Swap")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - QR Generation

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
