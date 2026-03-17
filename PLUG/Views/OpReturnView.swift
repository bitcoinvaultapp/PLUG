import SwiftUI

struct OpReturnView: View {
    @StateObject private var vm = OpReturnVM()

    var body: some View {
        NavigationStack {
            Form {
                PlugHeader(pageName: "OP_RETURN")

                Section("Mode") {
                    Picker("Type", selection: $vm.mode) {
                        ForEach(OpReturnVM.OpReturnMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(vm.mode == .text ? "Text memo" : "Data to hash") {
                    TextEditor(text: $vm.textInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                }

                Section("Optional payment") {
                    TextField("Payment address", text: $vm.paymentAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never)
                    TextField("Amount (sats)", text: $vm.paymentAmount)
                        .keyboardType(.numberPad)
                }

                Section("Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Size:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(vm.payloadSize) / 80 bytes")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(vm.isOverLimit ? .red : .primary)
                        }

                        // Size indicator bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 8)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(vm.isOverLimit ? Color.red : Color.green)
                                    .frame(width: min(geo.size.width, geo.size.width * CGFloat(vm.payloadSize) / 80.0), height: 8)
                            }
                        }
                        .frame(height: 8)

                        if !vm.opReturnHex.isEmpty {
                            Text("Hex: \(vm.opReturnHex.prefix(64))\(vm.opReturnHex.count > 64 ? "..." : "")")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = vm.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                if let result = vm.result {
                    Section("Result") {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button("Build PSBT") {
                        if let psbt = vm.buildTransaction() {
                            let base64 = psbt.base64EncodedString()
                            vm.result = base64
                            UIPasteboard.general.string = base64
                        }
                    }
                    .disabled(vm.textInput.isEmpty || vm.isOverLimit)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
    }
}
