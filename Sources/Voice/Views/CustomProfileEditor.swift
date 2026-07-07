import SwiftUI

/// Whether the editor sheet is creating a new profile or editing an existing one.
enum ProfileEditorMode: Identifiable {
    case new
    case edit(CustomProfile)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let profile): profile.id.uuidString
        }
    }
}

/// Sheet for creating/editing a custom profile (name + prompt). Shared by the
/// refinement and speech-summary profile lists — save/delete route through the
/// callbacks the call site provides.
struct CustomProfileEditor: View {
    let mode: ProfileEditorMode
    let caption: String
    let onSave: (UUID?, String, String) -> Void
    let onDelete: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var prompt: String

    init(
        mode: ProfileEditorMode,
        caption: String,
        onSave: @escaping (UUID?, String, String) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        self.mode = mode
        self.caption = caption
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .new:
            _name = State(initialValue: "")
            _prompt = State(initialValue: "")
        case .edit(let profile):
            _name = State(initialValue: profile.name)
            _prompt = State(initialValue: profile.prompt)
        }
    }

    private var editingID: UUID? {
        if case .edit(let profile) = mode { return profile.id }
        return nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingID == nil ? "New Profile" : "Edit Profile")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.subheadline.weight(.medium))
                TextField("e.g. Slack", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let editingID {
                    Button(role: .destructive) {
                        onDelete(editingID)
                        dismiss()
                    } label: {
                        Text("Delete")
                    }
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(editingID, name, prompt)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
