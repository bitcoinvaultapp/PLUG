import SwiftUI

struct ScriptEditorView: View {
    @StateObject private var vm = ScriptVM()

    var body: some View {
        NavigationStack {
            List {
                HStack {
                    PlugHeader(pageName: "Script")
                    Spacer()
                    HStack(spacing: 12) {
                        Button("Reset") { vm.reset() }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button("Run") { vm.execute() }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.btcOrange)
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
        }
    }
}
