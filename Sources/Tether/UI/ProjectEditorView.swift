import SwiftUI
import AppKit

struct ProjectEditorView: View {
    let projectID: UUID?

    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProjectConfig = ProjectConfig()
    @State private var loaded = false

    var body: some View {
        Form {
            Section("General") {
                TextField("Project name", text: $draft.name)
                Toggle("Enabled", isOn: $draft.isEnabled)
            }

            Section("Project roots") {
                pathRow(
                    label: "Local project folder",
                    text: $draft.localRootPath,
                    chooseDirectory: true
                )
                TextField(
                    "Remote project path",
                    text: $draft.remoteRootPath,
                    prompt: Text("user@host:/srv/myapp")
                )
            }

            Section("Sub-folders (relative to the roots above)") {
                HStack {
                    Text("Code sub-folder").frame(width: 140, alignment: .leading)
                    TextField("code", text: $draft.codeSubpath)
                }
                if !draft.localRootPath.isEmpty && !draft.codeSubpath.isEmpty {
                    Text("→ \(draft.localCodePath)   ⇆   \(draft.remoteCodePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Log sub-folder").frame(width: 140, alignment: .leading)
                    TextField("logs", text: $draft.logSubpath)
                }
                if !draft.localRootPath.isEmpty && !draft.logSubpath.isEmpty {
                    Text("→ \(draft.localLogPath)   ⇆   \(draft.remoteLogPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Pull every").frame(width: 140, alignment: .leading)
                    Stepper(value: $draft.pullIntervalSeconds, in: 30...86400, step: 30) {
                        Text("\(draft.pullIntervalSeconds) s")
                    }
                    .labelsHidden()
                    Text("\(draft.pullIntervalSeconds) seconds")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Advanced") {
                pathRow(
                    label: "SSH identity file",
                    text: Binding(
                        get: { draft.sshIdentityFile ?? "" },
                        set: { draft.sshIdentityFile = $0.isEmpty ? nil : $0 }
                    ),
                    chooseDirectory: false
                )
                TextField(
                    "Extra rsync args (space-separated)",
                    text: Binding(
                        get: { draft.extraRsyncArgs.joined(separator: " ") },
                        set: { draft.extraRsyncArgs = $0.split(separator: " ").map(String.init) }
                    )
                )
            }

            Section {
                HStack {
                    if projectID != nil {
                        Button(role: .destructive) {
                            if let id = projectID {
                                store.remove(id)
                            }
                            dismiss()
                        } label: {
                            Text("Delete")
                        }
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        guard !loaded else { return }
        loaded = true
        if let id = projectID, let existing = store.project(id) {
            draft = existing
        } else if let id = projectID {
            // New project — preserve the UUID the window was opened with so
            // repeated openings of the same window don't create duplicates on save.
            draft = ProjectConfig(id: id)
        } else {
            draft = ProjectConfig()
        }
    }

    private func save() {
        if store.project(draft.id) != nil {
            store.update(draft)
        } else {
            store.add(draft)
        }
    }

    @ViewBuilder
    private func pathRow(label: String, text: Binding<String>, chooseDirectory: Bool) -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
            TextField("", text: text)
            Button("Choose…") {
                if let picked = pickPath(directories: chooseDirectory) {
                    text.wrappedValue = picked
                }
            }
        }
    }

    private func pickPath(directories: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }
}
