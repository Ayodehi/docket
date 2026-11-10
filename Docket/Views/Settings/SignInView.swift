import GitHubKit
import SwiftUI

struct SignInView: View {
    @Environment(\.appState) private var app
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    private static let classicURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=Docket")!
    private static let fineGrainedURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to GitHub").font(.title2.weight(.semibold))
            Text("Docket needs a personal access token that can read your pull requests. It is stored in your login Keychain and sent only to api.github.com.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Link("Create a classic token (scopes: repo, read:org). Recommended.", destination: Self.classicURL)
                Link("Create a fine-grained token (resource owner: your organization; read: pull requests, commit statuses, contents; organization members)", destination: Self.fineGrainedURL)
                Text("Fine-grained tokens have no Checks permission, so CI results from GitHub Actions may not show. Organization permissions such as Members appear only when the resource owner is an organization.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            SecureField("Personal access token", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(busy ? "Checking…" : "Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Button("Import from GitHub CLI") { importFromGH() }
                    .disabled(busy)
                    .help("Uses the token gh is signed in with. It may have broader scopes than Docket needs.")
            }
        }
    }

    private func importFromGH() {
        busy = true
        error = nil
        Task {
            do {
                try await app.importTokenFromGitHubCLI()
            } catch let failure as GitHubError {
                error = failure.userMessage
            } catch {
                self.error = String(describing: error)
            }
            busy = false
        }
    }

    private func submit() {
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await app.signIn(token: candidate)
                token = ""
            } catch let failure as GitHubError {
                error = failure.userMessage
            } catch {
                self.error = "Could not save the token to the Keychain."
            }
            busy = false
        }
    }
}
