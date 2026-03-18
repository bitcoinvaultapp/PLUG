import SwiftUI

struct ScriptEditorView: View {
    @StateObject private var vm = ScriptVM()
    @State private var showTemplates = false
    @State private var showReference = false
    @State private var showLessons = false
    @State private var showDecoder = false

    var body: some View {
        NavigationStack {
            List {
                HStack {
                    PlugHeader(pageName: "Script")
                    Spacer()
                    HStack(spacing: 6) {
                        Button { vm.reset() } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Button {
                            if vm.isStepping { vm.stepForward() } else { vm.startStepping() }
                        } label: {
                            Image(systemName: vm.isStepping ? "forward.frame.fill" : "forward.frame")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.btcOrange)
                                .frame(width: 30, height: 30)
                                .background(Color.btcOrange.opacity(0.15), in: Circle())
                        }
                        Button { vm.execute() } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.green, in: Circle())
                        }
                    }
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

                // Step-by-step indicator
                if vm.isStepping {
                    Section {
                        VStack(spacing: 6) {
                            HStack {
                                Text("Step \(vm.currentStep)/\(vm.tokens.count)")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.btcOrange)
                                Spacer()
                                if vm.currentStep < vm.tokens.count {
                                    Text(vm.tokens[vm.currentStep])
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.green)
                                } else {
                                    Text("Done")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            // Token highlight bar
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(vm.tokens.indices, id: \.self) { i in
                                        Text(vm.tokens[i])
                                            .font(.system(size: 10, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                i < vm.currentStep ? Color.green.opacity(0.2) :
                                                i == vm.currentStep ? Color.btcOrange.opacity(0.3) :
                                                Color(.systemGray5),
                                                in: RoundedRectangle(cornerRadius: 4)
                                            )
                                            .foregroundStyle(
                                                i < vm.currentStep ? .green :
                                                i == vm.currentStep ? Color.btcOrange :
                                                .secondary
                                            )
                                    }
                                }
                            }
                        }
                    }
                }

                // Tools
                Section {
                    HStack(spacing: 8) {
                        scriptActionButton(icon: "doc.text.fill", title: "Templates", color: Color.btcOrange) {
                            showTemplates = true
                        }
                        scriptActionButton(icon: "book.fill", title: "Opcodes", color: .blue) {
                            showReference = true
                        }
                        scriptActionButton(icon: "graduationcap.fill", title: "Lessons", color: .purple) {
                            showLessons = true
                        }
                        scriptActionButton(icon: "doc.viewfinder", title: "Decode", color: .teal) {
                            showDecoder = true
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
            .sheet(isPresented: $showLessons) {
                ScriptLessonsSheet(scriptText: $vm.scriptText)
            }
            .sheet(isPresented: $showDecoder) {
                ScriptDecoderSheet()
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

// MARK: - Guided Lessons

struct ScriptLessonsSheet: View {
    @Binding var scriptText: String
    @Environment(\.dismiss) private var dismiss
    private let lessons: [(String, String, String, String)] = [
        ("1. The Stack", "Push numbers, then add them", "Bitcoin Script uses a stack. Numbers are pushed on. OP_ADD pops two, adds them, pushes the result. Use Step to watch.", "3 5 OP_ADD"),
        ("2. Verification", "Check if two values are equal", "OP_EQUAL pops two items, pushes TRUE if they match. A script is valid when TRUE is on top.", "2 3 OP_ADD 5 OP_EQUAL"),
        ("3. P2PKH", "Pay-to-Public-Key-Hash", "OP_DUP duplicates the pubkey. OP_HASH160 hashes it. OP_EQUALVERIFY checks the hash. OP_CHECKSIG verifies the signature. Every legacy Bitcoin address uses this.", "OP_DUP OP_HASH160 <pubkey_hash> OP_EQUALVERIFY OP_CHECKSIG"),
        ("4. Multisig", "M-of-N signatures", "Requires 2 of 3 signatures. Used for shared custody and escrow. PLUG's Pool contract uses this.", "2 <pk_A> <pk_B> <pk_C> 3 OP_CHECKMULTISIG"),
        ("5. Timelocks", "Lock until block height", "OP_CHECKLOCKTIMEVERIFY fails if block height < N. Funds locked until then. PLUG's Vault uses this.", "<pk> OP_CHECKSIGVERIFY 800000 OP_CHECKLOCKTIMEVERIFY"),
        ("6. CSV", "Relative timelock", "OP_CHECKSEQUENCEVERIFY enforces N blocks after confirmation. Used for inheritance.", "<heir> OP_CHECKSIGVERIFY 4320 OP_CHECKSEQUENCEVERIFY"),
        ("7. Hash Locks", "Reveal a secret to spend", "OP_SHA256 hashes the input. Must match the expected hash. Basis of HTLCs and atomic swaps.", "OP_SHA256 <hash> OP_EQUAL"),
        ("8. IF/ELSE", "Conditional branching", "OP_IF/OP_ELSE/OP_ENDIF enables complex conditions like 'Alice OR (Bob after timeout)'.", "<cond> OP_IF <path_A> OP_ELSE <path_B> OP_ENDIF"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(lessons, id: \.0) { title, desc, explanation, script in
                    Button {
                        scriptText = script
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                            Text(desc).font(.caption).foregroundStyle(Color.btcOrange)
                            Text(explanation).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Text(script)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Script Lessons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - Script Decoder

struct ScriptDecoderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hexInput = ""
    @State private var decoded: [(offset: Int, hex: String, meaning: String)] = []
    @State private var decodeError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Paste raw script hex...", text: $hexInput)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Decode") { decodeScript() }
                        .disabled(hexInput.isEmpty)
                } header: { Text("Raw Script (hex)") }
                  footer: { Text("Paste a scriptPubKey or witnessScript to see its opcodes.") }

                if let decodeError {
                    Section { Text(decodeError).font(.caption).foregroundStyle(.red) }
                }

                if !decoded.isEmpty {
                    Section("Decoded") {
                        ForEach(decoded, id: \.offset) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(format: "%02d", item.offset))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.meaning)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(item.meaning.hasPrefix("OP_") ? Color.btcOrange : .green)
                                    Text(item.hex)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Human-Readable") {
                        Text(decoded.map { $0.meaning }.joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Script Decoder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func decodeScript() {
        decoded.removeAll(); decodeError = nil
        let hex = hexInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "0x", with: "")
        guard let data = Data(hex: hex) else { decodeError = "Invalid hex"; return }
        var off = 0; var pos = 0
        while off < data.count {
            let b = data[off]
            if b == 0x00 { decoded.append((pos, "00", "OP_0")); off += 1 }
            else if b >= 0x01 && b <= 0x4b {
                let n = Int(b); let end = min(off+1+n, data.count); let d = Data(data[(off+1)..<end])
                decoded.append((pos, String(format: "%02x", b) + d.hex, "<\(n)B> \(d.hex)")); off += 1+n
            } else if let op = OpCode(rawValue: b) {
                decoded.append((pos, String(format: "%02x", b), op.name)); off += 1
            } else { decoded.append((pos, String(format: "%02x", b), "UNKNOWN")); off += 1 }
            pos += 1
        }
        if decoded.isEmpty { decodeError = "Empty script" }
    }
}
