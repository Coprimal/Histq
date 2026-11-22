// The offer to import a workspace file's profiles that this Mac lacks (`WindowModal.importProfiles`): what each one
// sets (identity, signing key, SSH key file, code host accounts), so the user sees the key paths and hosts they
// accept. Opened once when a workspace opens and from a missing-profile tab's "Import <name>…"; only Import adds them.
import HistqCore
import SwiftUI

extension Profile {
    /// The code host accounts the profile signs in with, as "<login> on <host>" (just the host with no login). The
    /// one place the app reads `github` for display, so another account model can replace it here.
    var codeHostAccounts: [String] {
        guard let github else { return [] }
        let login = github.login.trimmingCharacters(in: .whitespacesAndNewlines)
        return [login.isEmpty ? github.host : "\(login) on \(github.host)"]
    }
}

/// One card per profile, then Not Now (Escape: the tabs keep their badges) and Import. Return does not import: the
/// file may come from anyone, so accepting it takes a click.
struct ProfileImportSheet: View {
    let profiles: [Profile]
    /// The workspace file's name, shown in the explanation.
    let workspaceName: String
    let onImport: () -> Void
    let onClose: () -> Void
    /// The cards' height, the scroll view's cap.
    @State private var cardsHeight: CGFloat = 120

    var body: some View {
        ModalCard(title: profiles.count == 1 ? "Import a profile?" : "Import \(profiles.count) profiles?",
                  systemImage: "person.crop.circle.badge.plus", width: 480, takesFocus: true) {
            VStack(alignment: .leading, spacing: PanelContainerMetrics.padding) {
                Text("\(workspaceName.isEmpty ? "A workspace file" : "The workspace file \"\(workspaceName)\"") defines \(profiles.count == 1 ? "this profile" : "these profiles"), "
                    + "which this Mac does not have. Import adds \(profiles.count == 1 ? "it" : "them") to Settings › "
                    + "Profiles. Check the keys and accounts first.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
                ScrollView {
                    VStack(alignment: .leading, spacing: PanelContainerMetrics.padding) {
                        ForEach(profiles) { card($0) }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { cardsHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: cardsHeight)
            }
        } actions: {
            Button("Not Now", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            Button("Import", action: onImport)
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
        }
    }

    private func card(_ profile: Profile) -> some View {
        ModalSection(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ProfileColors.color(profile.color))
                    .frame(width: 10, height: 10)
                Text(ProfilePicker.title(profile))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            row("Identity", identity(profile))
            row("Signing", signing(profile.signing))
            row("SSH key", ssh(profile.ssh))
            row("Accounts", profile.codeHostAccounts.isEmpty ? "None" : profile.codeHostAccounts.joined(separator: "\n"))
        }
    }

    /// A label and its value; the value wraps (a key path is shown whole) and can be selected.
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func identity(_ profile: Profile) -> String {
        let name = profile.identity.name, email = profile.identity.email
        if name.isEmpty { return email.isEmpty ? "Not set" : email }
        return email.isEmpty ? name : "\(name) <\(email)>"
    }

    private func signing(_ signing: Profile.Signing) -> String {
        switch signing {
        case .none: "None"
        case .gpg(let keyID): "GPG key \(keyID)"
        case .ssh(let keyPath): "SSH key \(ProfileLibrary.abbreviated(keyPath))"
        }
    }

    private func ssh(_ ssh: Profile.SSHKey) -> String {
        switch ssh {
        case .agent: "SSH agent"
        case .keyFile(let path): ProfileLibrary.abbreviated(path)
        }
    }

    /// Adds `profiles` the library lacks to Settings › Profiles (never the default or a repo's profile) and makes them
    /// `workspace`'s baseline, so a later edit in Settings is written to its file. The sheet's Import, and the DEBUG
    /// `-HistqImportProfiles YES` seam.
    static func importProfiles(_ profiles: [Profile], into workspace: Workspace?) {
        var added: [Profile] = []
        ProfileLibrary.shared.update { added = $0.importProfiles(profiles) }
        workspace?.adoptBaseline(added)
    }
}
