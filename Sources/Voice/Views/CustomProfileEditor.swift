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

/// Sheet for creating/editing a custom refinement profile: a name plus a prompt
/// that drives the cleanup tone. Save/Delete route through `AppSettings`.
struct CustomProfileEditor: View {
    @ObservedObject var settings: AppSettings
    let mode: ProfileEditorMode

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var prompt: String

    init(settings: AppSettings, mode: ProfileEditorMode) {
        self.settings = settings
        self.mode = mode
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
                Text("Describe the tone and style, e.g. \"Rewrite as terse lowercase Slack messages, no emoji.\" It becomes the tone profile for cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let editingID {
                    Button(role: .destructive) {
                        settings.deleteCustomProfile(editingID)
                        dismiss()
                    } label: {
                        Text("Delete")
                    }
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    settings.upsertCustomProfile(id: editingID, name: name, prompt: prompt)
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
