import SwiftUI

struct ScriptEditorView: View {
    @StateObject private var vm = ScriptVM()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PlugHeader(pageName: "Script")
                    .padding(.horizontal)

                // Script input
                scriptInput

                Divider()

                // Quick opcodes
                quickOpcodes

                Divider()

                // Output
                outputSection
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run") { vm.execute() }
                        .fontWeight(.bold)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { vm.reset() }
                }
            }
        }
    }

    // MARK: - Script input

    private var scriptInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Script")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            TextEditor(text: $vm.scriptText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 160)
                .padding(.horizontal, 4)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
        }
        .padding(.top)
    }

    // MARK: - Quick opcodes

    private var quickOpcodes: some View {
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
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status
            if let isValid = vm.isValid {
                HStack {
                    Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isValid ? .green : .red)
                    Text(isValid ? "VALID" : "INVALID")
                        .font(.headline)
                        .foregroundStyle(isValid ? .green : .red)
                }
                .padding(.horizontal)
            }

            // Stack
            if !vm.stack.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stack (\(vm.stack.count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

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
                .padding(.horizontal)
            }

            // Log
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.log.indices, id: \.self) { i in
                        Text(vm.log[i])
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(vm.log[i].hasPrefix("ERROR") ? .red : .primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            if let error = vm.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }
}
