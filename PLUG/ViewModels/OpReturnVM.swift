import Foundation

@MainActor
final class OpReturnVM: ObservableObject {

    enum OpReturnMode: String, CaseIterable {
        case text
        case sha256

        var label: String {
            switch self {
            case .text: return "Text Memo"
            case .sha256: return "SHA256 Proof"
            }
        }
    }

    @Published var mode: OpReturnMode = .text
    @Published var textInput: String = ""
    @Published var paymentAddress: String = ""
    @Published var paymentAmount: String = ""
    @Published var result: String?  // txid after broadcast
    @Published var isLoading = false
    @Published var error: String?

    var isTestnet: Bool { NetworkConfig.shared.isTestnet }

    /// The hex data that will be embedded in OP_RETURN
    var opReturnHex: String {
        let payload = opReturnPayload
        return payload.hex
    }

    /// Size of the OP_RETURN payload in bytes
    var payloadSize: Int {
        opReturnPayload.count
    }

    /// Whether payload exceeds the 80-byte standard limit
    var isOverLimit: Bool {
        payloadSize > 80
    }

    /// Compute the OP_RETURN payload
    private var opReturnPayload: Data {
        switch mode {
        case .text:
            return Data(textInput.utf8)
        case .sha256:
            let inputData = Data(textInput.utf8)
            guard !inputData.isEmpty else { return Data() }
            return Crypto.sha256(inputData)
        }
    }

    /// Build the OP_RETURN transaction as a PSBT
    func buildTransaction() -> Data? {
        guard !textInput.isEmpty else {
            error = "Empty input"
            return nil
        }

        guard !isOverLimit else {
            error = "Data exceeds the 80-byte limit"
            return nil
        }

        let payload = opReturnPayload

        // Build OP_RETURN scriptPubKey: OP_RETURN <data>
        let opReturnScript = ScriptBuilder()
            .addOp(.op_return)
            .pushData(payload)

        var outputs: [PSBTBuilder.TxOutput] = [
            PSBTBuilder.TxOutput(value: 0, scriptPubKey: opReturnScript.script)
        ]

        // Optional payment output
        if !paymentAddress.isEmpty, let amountSats = UInt64(paymentAmount), amountSats > 0 {
            guard let paymentScript = PSBTBuilder.scriptPubKeyFromAddress(paymentAddress, isTestnet: isTestnet) else {
                error = "Invalid payment address"
                return nil
            }
            outputs.append(PSBTBuilder.TxOutput(value: amountSats, scriptPubKey: paymentScript))
        }

        // Note: In a full implementation, UTXOs and inputs would be selected here.
        // For now we return the PSBT structure with outputs only.
        let psbt = PSBTBuilder.buildPSBT(inputs: [], outputs: outputs)
        if psbt == nil {
            error = "Unable to build PSBT"
        }
        return psbt
    }
}
