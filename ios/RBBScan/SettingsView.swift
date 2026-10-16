import PasscodeCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var testResult: String?
    @State private var testing = false

    private var draftURL: URL? { ScanViewModel.validatedURL(draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.y.z:8787", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if draftURL == nil {
                        Text("Enter an http:// or https:// address.").foregroundStyle(.red).font(.footnote)
                    }
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                        .disabled(draftURL == nil || testing)
                    if let testResult {
                        Text(testResult).font(.footnote)
                    }
                } header: {
                    Text("Mac mini server")
                } footer: {
                    Text("The Mac's Tailscale address. Open /live on another device to watch scans as they happen.")
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.serverURLString = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await model.syncWithServer() }
                        dismiss()
                    }
                    .disabled(draftURL == nil)
                }
            }
            .onAppear { draft = model.serverURLString }
        }
    }

    private func test() async {
        guard let url = draftURL else { return }
        testing = true
        defer { testing = false }
        do {
            let stats = try await ScanClient(baseURL: url).stats()
            testResult = "✅ Connected: \(stats.uniqueTotal) of \(stats.targetTotal) passcodes on the server."
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
