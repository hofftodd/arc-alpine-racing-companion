import RulebookKit
import RulebookMLX
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var model = model
        Form {
            ContextDefaultsSections(context: $model.defaultContext)

            Section {
                Picker("Answer engine", selection: $model.preference) {
                    ForEach(EnginePreference.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("In use", value: model.engineName)
            } footer: {
                Text("Automatic uses Qwen3 4B when it's downloaded and the device has enough memory, then Apple Intelligence, then search only. Everything runs on this device; questions never leave it.")
            }

            Section("Qwen3 4B model") {
                modelStatus
                if !ModelManager.deviceIsCapable {
                    Text("This device has less than 6 GB of memory, so Qwen3 4B may be slow or be closed by the system. Apple Intelligence is recommended instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Apple Intelligence") {
                LabeledContent("Status", value: FoundationModelsBackend.unavailableReason ?? "Available")
            }

            Section("Documents") {
                LabeledContent("Bundled documents", value: "\(model.store?.documents.count ?? 0)")
                Text("Browse them in the Library.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            #endif
        }
        .confirmationDialog("Delete the downloaded model?", isPresented: $confirmDelete) {
            Button("Delete Model", role: .destructive) { model.modelManager.deleteDownload() }
        } message: {
            Text("You can download it again later (\(ModelManager.approximateDownloadSize)).")
        }
        .onChange(of: model.preference) {
            if model.preference == .mlx || model.preference == .automatic, model.modelManager.isDownloaded {
                model.modelManager.prepare()
            }
        }
    }

    @ViewBuilder private var modelStatus: some View {
        let manager = model.modelManager
        switch manager.state {
        case .notDownloaded:
            Button("Download (\(ModelManager.approximateDownloadSize), Wi-Fi recommended)", systemImage: "arrow.down.circle") {
                manager.prepare()
            }
        case .downloading(let progress):
            ProgressView(value: progress) { Text("Downloading…") }
            Button("Cancel", role: .cancel) { manager.cancel() }
        case .downloaded:
            LabeledContent("Status", value: "Downloaded")
            Button("Load now") { manager.prepare() }
            deleteButton
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading…") }
        case .ready:
            LabeledContent("Status", value: "Ready")
            deleteButton
        case .failed(let message):
            Text(message).foregroundStyle(.red).font(.caption)
            Button("Try Again") { manager.prepare() }
            if manager.isDownloaded { deleteButton }
        }
    }

    private var deleteButton: some View {
        Button("Delete Model", role: .destructive) { confirmDelete = true }
    }
}
