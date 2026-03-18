import SwiftUI

struct ScriptEditorView: View {
    @StateObject private var vm = ScriptVM()
    @State private var showTemplates = false
    @State private var showReference = false

    var body: some View {
        NavigationStack {
            List {
                HStack {
                    PlugHeader(pageName: "Script")
                    Spacer()
                    HStack(spacing: 12) {
                        Button { vm.reset() } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Button { vm.execute() } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.trailing, 12)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Script input
                Section {
                    TextEditor(text: $vm.scriptText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                        .scrollContentBackground(.hidden)

                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Label("Done", systemImage: "keyboard.chevron.compact.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Script")
                }

                // Templates & Opcodes
                Section {
                    HStack(spacing: 10) {
                        scriptActionButton(icon: "doc.text.fill", title: "Templates", color: Color.btcOrange) {
                            showTemplates = true
                        }
                        scriptActionButton(icon: "book.fill", title: "Opcodes", color: .blue) {
                            showReference = true
                        }
                    }
                }

                // Quick opcodes
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ScriptVM.quickOpcodes, id: \.0) { label, opcode in
                                Button(label) {
                                    if !vm.scriptText.isEmpty && !vm.scriptText.hasSuffix(" ") {
                                        vm.scriptText += " "
                                    }
                                    vm.scriptText += opcode
                                }
                                .font(.system(.caption2, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                // Output
                if let isValid = vm.isValid {
                    Section {
                        HStack {
                            Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isValid ? .green : .red)
                            Text(isValid ? "VALID" : "INVALID")
                                .font(.headline)
                                .foregroundStyle(isValid ? .green : .red)
                        }
                    }
                }

                if !vm.stack.isEmpty {
                    Section("Stack (\(vm.stack.count))") {
                        ForEach(vm.stack.indices.reversed(), id: \.self) { i in
                            HStack {
                                Text("[\(i)]")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                                Text(vm.stack[i].isEmpty ? "(empty)" : vm.stack[i].hex)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }

                if !vm.log.isEmpty {
                    Section("Log") {
                        ForEach(vm.log.indices, id: \.self) { i in
                            Text(vm.log[i])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(vm.log[i].hasPrefix("ERROR") ? .red : .primary)
                        }
                    }
                }

                if let error = vm.error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showTemplates) {
                ScriptTemplatesSheet(scriptText: $vm.scriptText)
            }
            .sheet(isPresented: $showReference) {
                OpcodeReferenceSheet()
            }
        }
    }

    private func scriptActionButton(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(color == .secondary ? .primary : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Script Templates (from Mastering Bitcoin)

struct ScriptTemplatesSheet: View {
    @Binding var scriptText: String
    @Environment(\.dismiss) private var dismiss

    private let templates: [(category: String, items: [(name: String, desc: String, script: String)])] = [
        ("Basics", [
            ("Simple Math", "2 + 3 = 5 verification", "2 3 OP_ADD 5 OP_EQUAL"),
            ("Stack Ops", "Duplicate and verify equal", "42 OP_DUP OP_EQUAL"),
            ("Boolean Logic", "NOT of FALSE = TRUE", "0 OP_NOT"),
            ("Multi-step Math", "2*7 - 3 + 1 = 12", "2 7 OP_ADD 3 OP_SUB 1 OP_ADD 7 OP_EQUAL"),
        ]),
        ("Standard Scripts", [
            ("P2PKH", "Pay to Public Key Hash — classic Bitcoin address", "OP_DUP OP_HASH160 <pubkey_hash> OP_EQUALVERIFY OP_CHECKSIG"),
            ("P2PK", "Pay to Public Key — original Satoshi format", "<pubkey> OP_CHECKSIG"),
            ("Multisig 2-of-3", "Requires 2 of 3 signatures", "2 <pubkey_A> <pubkey_B> <pubkey_C> 3 OP_CHECKMULTISIG"),
            ("OP_RETURN", "Embed data (unspendable)", "OP_RETURN <data>"),
        ]),
        ("Timelocks", [
            ("CLTV Vault", "Locked until block height N", "<pubkey> OP_CHECKSIGVERIFY 800000 OP_CHECKLOCKTIMEVERIFY"),
            ("CSV Inheritance", "Owner OR heir after delay", "<owner> OP_CHECKSIG OP_IFDUP OP_NOTIF <heir> OP_CHECKSIGVERIFY 4320 OP_CHECKSEQUENCEVERIFY OP_ENDIF"),
            ("Time-locked Refund", "Refundable after timeout", "<timeout> OP_CHECKLOCKTIMEVERIFY OP_DROP <pubkey> OP_CHECKSIG"),
        ]),
        ("Hash Locks", [
            ("Hash Lock (SHA256)", "Reveal preimage to spend", "OP_SHA256 <hash> OP_EQUAL"),
            ("Hash Lock (HASH160)", "RIPEMD160(SHA256(x))", "OP_HASH160 <hash160> OP_EQUAL"),
            ("HTLC", "Hash + timelock conditional", "<receiver> OP_CHECKSIG OP_NOTIF <sender> OP_CHECKSIGVERIFY <timeout> OP_CHECKLOCKTIMEVERIFY OP_ELSE OP_SIZE 32 OP_EQUALVERIFY OP_SHA256 <hash> OP_EQUAL OP_ENDIF"),
        ]),
        ("Advanced", [
            ("Payment Channel", "2-of-2 + timeout refund", "2 <sender> <receiver> 2 OP_CHECKMULTISIG OP_IFDUP OP_NOTIF <sender> OP_CHECKSIGVERIFY <timeout> OP_CHECKLOCKTIMEVERIFY OP_ENDIF"),
            ("Puzzle: Sum = 15", "Two numbers that add to 15", "OP_ADD 15 OP_EQUAL"),
            ("Hash Chain", "Double hash verification", "OP_SHA256 OP_SHA256 <double_hash> OP_EQUAL"),
        ]),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(templates, id: \.category) { section in
                    Section(section.category) {
                        ForEach(section.items, id: \.name) { item in
                            Button {
                                scriptText = item.script
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(item.desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item.script)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color.btcOrange)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Script Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Opcode Reference (from Mastering Bitcoin ch7)

struct OpcodeReferenceSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let opcodes: [(category: String, items: [(op: String, hex: String, desc: String)])] = [
        ("Constants", [
            ("OP_0 / OP_FALSE", "0x00", "Push empty byte array (false)"),
            ("OP_1 / OP_TRUE", "0x51", "Push the number 1 (true)"),
            ("OP_1NEGATE", "0x4f", "Push the number -1"),
            ("OP_2 — OP_16", "0x52-60", "Push the number 2-16"),
        ]),
        ("Stack", [
            ("OP_DUP", "0x76", "Duplicate top stack item"),
            ("OP_DROP", "0x75", "Remove top stack item"),
            ("OP_SWAP", "0x7c", "Swap top two items"),
            ("OP_OVER", "0x78", "Copy second-to-top item to top"),
            ("OP_ROT", "0x7b", "Rotate top three items"),
            ("OP_2DUP", "0x6e", "Duplicate top two items"),
            ("OP_IFDUP", "0x73", "Duplicate if not zero"),
            ("OP_SIZE", "0x82", "Push size of top item"),
        ]),
        ("Arithmetic", [
            ("OP_ADD", "0x93", "Add top two items"),
            ("OP_SUB", "0x94", "Subtract top from second"),
            ("OP_1ADD", "0x8b", "Add 1 to top item"),
            ("OP_1SUB", "0x8c", "Subtract 1 from top item"),
            ("OP_NEGATE", "0x8f", "Negate top item"),
            ("OP_ABS", "0x90", "Absolute value"),
            ("OP_NOT", "0x91", "Boolean NOT (0→1, else→0)"),
            ("OP_MIN", "0xa3", "Return smaller of two"),
            ("OP_MAX", "0xa4", "Return larger of two"),
            ("OP_WITHIN", "0xa5", "Check if value is within range"),
        ]),
        ("Logic / Comparison", [
            ("OP_EQUAL", "0x87", "True if top two items are equal"),
            ("OP_EQUALVERIFY", "0x88", "OP_EQUAL + OP_VERIFY"),
            ("OP_VERIFY", "0x69", "Fail if top is not true"),
            ("OP_RETURN", "0x6a", "Mark output as unspendable"),
            ("OP_NUMEQUAL", "0x9c", "True if numbers are equal"),
            ("OP_LESSTHAN", "0x9f", "True if a < b"),
            ("OP_GREATERTHAN", "0xa0", "True if a > b"),
        ]),
        ("Crypto", [
            ("OP_SHA256", "0xa8", "SHA-256 hash of top item"),
            ("OP_HASH160", "0xa9", "RIPEMD160(SHA256(x))"),
            ("OP_HASH256", "0xaa", "SHA256(SHA256(x)) — double hash"),
            ("OP_RIPEMD160", "0xa6", "RIPEMD-160 hash"),
            ("OP_CHECKSIG", "0xac", "Verify signature against pubkey"),
            ("OP_CHECKSIGVERIFY", "0xad", "OP_CHECKSIG + OP_VERIFY"),
            ("OP_CHECKMULTISIG", "0xae", "Verify M-of-N signatures"),
            ("OP_CHECKMULTISIGVERIFY", "0xaf", "OP_CHECKMULTISIG + OP_VERIFY"),
        ]),
        ("Flow Control", [
            ("OP_IF", "0x63", "Execute if top is true"),
            ("OP_NOTIF", "0x64", "Execute if top is false"),
            ("OP_ELSE", "0x67", "Execute if previous IF was false"),
            ("OP_ENDIF", "0x68", "End IF block"),
            ("OP_NOP", "0x61", "Do nothing"),
        ]),
        ("Timelocks (BIP65/112)", [
            ("OP_CHECKLOCKTIMEVERIFY", "0xb1", "CLTV — fail if locktime not reached (absolute block height or time)"),
            ("OP_CHECKSEQUENCEVERIFY", "0xb2", "CSV — fail if relative timelock not met (blocks since input confirmed)"),
        ]),
        ("Taproot (BIP342)", [
            ("OP_CHECKSIGADD", "0xba", "Schnorr sig check, add result to accumulator (replaces OP_CHECKMULTISIG in tapscript)"),
        ]),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(opcodes, id: \.category) { section in
                    Section(section.category) {
                        ForEach(section.items, id: \.op) { item in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.op)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.btcOrange)
                                    Text(item.hex)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 140, alignment: .leading)

                                Text(item.desc)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Opcode Reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
