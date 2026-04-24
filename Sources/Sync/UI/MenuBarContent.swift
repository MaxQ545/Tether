import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ConfigStore.self) private var store

    @State private var pendingRemoval: ProjectConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if store.projects.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { idx, project in
                        projectRow(project)
                        if idx < store.projects.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }

            Divider()

            actionList
        }
        .frame(width: 320)
        .padding(.vertical, 6)
        .confirmationDialog(
            "Remove project?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { project in
            Button("Remove \(project.name.isEmpty ? "project" : "“\(project.name)”")", role: .destructive) {
                store.remove(project.id)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { project in
            Text("This will stop syncing \(project.name.isEmpty ? "this project" : "“\(project.name)”") and delete its configuration. Local and remote files are not touched.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sync")
                .font(.headline)
            Spacer()
            Button {
                SyncEngine.shared.syncAllNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Sync all enabled projects now")
            .disabled(store.projects.contains(where: \.isEnabled) == false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No projects yet")
                .foregroundStyle(.secondary)
            Text("Tap “Add Project…” below to create one.")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            actionRow(icon: "plus.circle", title: "Add Project…") {
                bringToFront()
                openWindow(id: "project-editor", value: UUID())
            }
            Divider().padding(.leading, 38)
            actionRow(icon: "power", title: "Quit") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Project row

    @ViewBuilder
    private func projectRow(_ project: ProjectConfig) -> some View {
        let binding = Binding<Bool>(
            get: { project.isEnabled },
            set: { store.setEnabled(project.id, $0) }
        )
        let projectStatus = store.status[project.id]

        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name.isEmpty ? "(unnamed)" : project.name)
                    .font(.body)
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    VStack(alignment: .leading, spacing: 3) {
                        statusRow(
                            icon: "arrow.up",
                            label: "code",
                            status: projectStatus?.code,
                            enabled: project.isEnabled
                        )
                        statusRow(
                            icon: "arrow.down",
                            label: "log",
                            status: projectStatus?.log,
                            enabled: project.isEnabled
                        )
                    }
                }
            }
            Spacer(minLength: 4)
            Button {
                bringToFront()
                openWindow(id: "project-editor", value: project.id)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Edit project")

            Button(role: .destructive) {
                pendingRemoval = project
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove project")

            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.leading, 2)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusRow(icon: String, label: String, status: SyncStatus?, enabled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .frame(width: 10)
            Text(label)
                .font(.caption)
            Text(statusText(status, enabled: enabled))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(color(for: status, enabled: enabled))
    }

    // MARK: - Reusable row for bottom actions

    @ViewBuilder
    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } onTap: {
            action()
        }
    }

    // MARK: - Status helpers

    private func statusText(_ status: SyncStatus?, enabled: Bool) -> String {
        switch status {
        case .syncing:
            return "syncing…"
        case .ok(let at):
            return "synced \(formatted(at))"
        case .failed(_, let msg):
            let first = msg.split(whereSeparator: \.isNewline).first.map(String.init) ?? msg
            return "error: \(first)"
        case .retryingAt(let at, _):
            let secs = max(0, Int(at.timeIntervalSinceNow.rounded(.up)))
            if secs <= 0 { return "retrying…" }
            if secs >= 60 {
                let mins = Int((Double(secs) / 60.0).rounded(.up))
                return "retry in \(mins)m"
            }
            return "retry in \(secs)s"
        case .idle, .none:
            return enabled ? "waiting" : "disabled"
        }
    }

    private func color(for status: SyncStatus?, enabled: Bool) -> Color {
        switch status {
        case .failed:      return .red
        case .ok:          return .secondary
        case .syncing:     return .blue
        case .retryingAt:  return .orange
        case .idle, .none: return enabled ? .secondary : .gray
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private func formatted(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A row that highlights on hover and dispatches a tap.
private struct HoverRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        content()
            .background(hovering ? Color.accentColor.opacity(0.18) : Color.clear)
            .onHover { hovering = $0 }
            .onTapGesture { onTap() }
    }
}
