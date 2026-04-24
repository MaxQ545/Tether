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

            Section("Push (local → remote)") {
                Toggle("Enabled", isOn: $draft.pushCodeEnabled)
                if draft.pushCodeEnabled {
                    subpathEditor(
                        label: "Sub-folders",
                        subpaths: $draft.codeSubpaths,
                        localPaths: draft.localCodePaths,
                        remotePaths: draft.remoteCodePaths,
                        rootFilled: !draft.localRootPath.isEmpty
                    )
                    excludeEditor(
                        label: "Excludes",
                        values: $draft.codeExcludes
                    )
                }
            }

            Section("Pull (remote → local)") {
                Toggle("Enabled", isOn: $draft.pullLogEnabled)
                if draft.pullLogEnabled {
                    subpathEditor(
                        label: "Sub-folders",
                        subpaths: $draft.logSubpaths,
                        localPaths: draft.localLogPaths,
                        remotePaths: draft.remoteLogPaths,
                        rootFilled: !draft.localRootPath.isEmpty
                    )
                    excludeEditor(
                        label: "Excludes",
                        values: $draft.logExcludes
                    )
                    HStack {
                        Text("Interval").frame(width: 140, alignment: .leading)
                        Stepper(value: $draft.pullIntervalSeconds, in: 30...86400, step: 30) {
                            Text("\(draft.pullIntervalSeconds) s")
                        }
                        .labelsHidden()
                        Text("\(draft.pullIntervalSeconds) seconds")
                            .foregroundStyle(.secondary)
                    }
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
        draft.codeSubpaths = sanitize(draft.codeSubpaths)
        draft.logSubpaths  = sanitize(draft.logSubpaths)
        draft.codeExcludes = sanitize(draft.codeExcludes)
        draft.logExcludes  = sanitize(draft.logExcludes)
        if store.project(draft.id) != nil {
            store.update(draft)
        } else {
            store.add(draft)
        }
    }

    private func sanitize(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }
             .filter { !$0.isEmpty }
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

    @ViewBuilder
    private func subpathEditor(
        label: String,
        subpaths: Binding<[String]>,
        localPaths: [String],
        remotePaths: [String],
        rootFilled: Bool
    ) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 140, alignment: .leading)
            multiLineEditor(
                text: Binding(
                    get: { subpaths.wrappedValue.joined(separator: "\n") },
                    set: {
                        subpaths.wrappedValue = $0
                            .split(separator: "\n", omittingEmptySubsequences: false)
                            .map(String.init)
                    }
                )
            )
        }
        if rootFilled {
            let nonEmpty = subpaths.wrappedValue.enumerated().filter { !$0.element.isEmpty }
            let shown = nonEmpty.prefix(3)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown), id: \.offset) { entry in
                    let idx = entry.offset
                    if idx < localPaths.count, idx < remotePaths.count {
                        Text("→ \(localPaths[idx])   ⇆   \(remotePaths[idx])")
                    }
                }
                if nonEmpty.count > shown.count {
                    Text("+\(nonEmpty.count - shown.count) more")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func excludeEditor(label: String, values: Binding<[String]>) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 140, alignment: .leading)
            multiLineEditor(
                text: Binding(
                    get: { values.wrappedValue.joined(separator: "\n") },
                    set: {
                        values.wrappedValue = $0
                            .split(separator: "\n", omittingEmptySubsequences: false)
                            .map(String.init)
                    }
                )
            )
        }
    }

    /// Multi-line text editor that treats Enter as a newline instead of firing
    /// the form's default Save action.
    @ViewBuilder
    private func multiLineEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 48, maxHeight: 120)
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )
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
