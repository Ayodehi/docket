import AppKit
import SwiftUI
import Workspace

/// Settings > Run: per-repo commands that start and stop a PR's checkout.
struct RunSettingsView: View {
    @Environment(\.appState) private var app
    @State private var repo = ""
    @State private var selected: UUID?
    @State private var detectNote: String?

    var body: some View {
        Form {
            Section {
                Picker("Repo", selection: $repo) {
                    Text("Choose a repo").tag("")
                    ForEach(repoChoices, id: \.self) { name in
                        let count = app.runSettings(for: name).profiles.count
                        Text(count == 0 ? name : "\(name) (\(count) \(count == 1 ? "profile" : "profiles"))").tag(name)
                    }
                }
            } footer: {
                Text("A run profile starts a PR's checkout with your own command, for example devspace dev with an env file. Run uses the same worktree or clone as Claude. Running another person's PR asks first, since it runs their code.")
                    .foregroundStyle(.secondary)
            }
            if !repo.isEmpty {
                profilesSection
                if let profile = settings.wrappedValue.profiles.first(where: { $0.id == selected }) {
                    ProfileEditor(profile: profileBinding(profile))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 560)
        .onAppear(perform: takeRequestedRepo)
        .onChange(of: app.runSettingsRepo) { takeRequestedRepo() }
        .onChange(of: repo) {
            selected = app.runSettings(for: repo).defaultProfile?.id
            detectNote = nil
        }
    }

    private var repoChoices: [String] {
        Array(Set(app.repos.map(\.name)).union(app.workspaceSettings.runProfiles.keys)).sorted()
    }

    private var settings: Binding<RepoRunSettings> {
        let repo = repo
        return Binding(get: { app.runSettings(for: repo) },
                       set: { app.workspaceSettings.runProfiles[repo] = $0.profiles.isEmpty ? nil : $0 })
    }

    /// Looks the profile up by ID on every access. A binding by array index crashes when a text
    /// field writes back after the profile is deleted.
    private func profileBinding(_ profile: RunProfile) -> Binding<RunProfile> {
        let settings = settings
        let id = profile.id
        return Binding(get: { settings.wrappedValue.profiles.first { $0.id == id } ?? profile },
                       set: { new in
                           guard let index = settings.wrappedValue.profiles.firstIndex(where: { $0.id == id }) else { return }
                           settings.wrappedValue.profiles[index] = new
                       })
    }

    private var profilesSection: some View {
        Section("Profiles") {
            ForEach(settings.wrappedValue.profiles) { profile in
                HStack {
                    let isDefault = settings.wrappedValue.defaultProfile?.id == profile.id
                    Button {
                        settings.wrappedValue.defaultID = profile.id
                    } label: {
                        Label(isDefault ? "Default" : "Make default", systemImage: isDefault ? "star.fill" : "star")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(isDefault ? "The Run button uses this profile" : "Use this profile for the Run button")
                    Text(profile.name).fontWeight(selected == profile.id ? .semibold : .regular)
                    Text(profile.kind.title).foregroundStyle(.secondary)
                    if isDefault { Text("default").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Edit") { selected = profile.id }.disabled(selected == profile.id)
                    Button {
                        settings.wrappedValue.profiles.removeAll { $0.id == profile.id }
                        if selected == profile.id { selected = nil }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Delete this profile")
                }
            }
            HStack {
                Button("Add Profile") { add(RunProfile(name: "New profile", command: "")) }
                Button("Detect") { detect() }
                    .disabled(app.clone(for: repo) == nil)
                    .help("Looks for devspace.yaml in this repo's clone and adds a profile for it. Nothing runs.")
                Spacer()
                if let detectNote { Text(detectNote).foregroundStyle(.secondary) }
            }
        }
    }

    private func add(_ profile: RunProfile) {
        settings.wrappedValue.profiles.append(profile)
        selected = profile.id
    }

    private func detect() {
        guard let clone = app.clone(for: repo) else { return }
        let existing = settings.wrappedValue.profiles
        let found = RunDetector.suggest(in: clone.path).filter { suggestion in
            !existing.contains { $0.kind == suggestion.kind && $0.workingDirectory == suggestion.workingDirectory }
        }
        found.forEach(add)
        detectNote = found.isEmpty ? "Nothing new found" : "Added \(found.count). Set the env file below."
    }

    private func takeRequestedRepo() {
        guard let requested = app.runSettingsRepo else { return }
        repo = requested
        app.runSettingsRepo = nil
    }
}

private struct ProfileEditor: View {
    @Environment(\.appState) private var app
    @Binding var profile: RunProfile
    @State private var contexts: [String] = []

    private func optional(_ keyPath: WritableKeyPath<RunProfile, String?>) -> Binding<String> {
        Binding(get: { profile[keyPath: keyPath] ?? "" }, set: { profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Section("Edit \(profile.name)") {
            TextField("Name", text: $profile.name)
            Picker("Kind", selection: $profile.kind) {
                ForEach(RunKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Folder", text: $profile.workingDirectory, prompt: Text("checkout root"))
                .font(.system(.body, design: .monospaced))
            if !RunPlanner.isValidRelativePath(profile.workingDirectory.trimmingCharacters(in: .whitespaces)) {
                Label("Use a path relative to the checkout, without \"..\".", systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warn.text)
            }
            TextField("Command", text: $profile.command, prompt: Text("devspace dev"))
                .font(.system(.body, design: .monospaced))
            TextField("Stop command", text: Binding(get: { profile.stopCommand ?? "" }, set: { profile.stopCommand = $0.isEmpty ? nil : $0 }),
                      prompt: Text("optional, for example devspace purge"))
                .font(.system(.body, design: .monospaced))
        }
        Section {
            LabeledContent("Context") {
                HStack {
                    TextField("Context", text: optional(\.kubeContext), prompt: Text(profile.kind == .devspace ? "required" : "none"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    Menu("Choose") {
                        if contexts.isEmpty { Text("No contexts found in your kubeconfig") }
                        ForEach(contexts, id: \.self) { name in Button(name) { profile.kubeContext = name } }
                    }
                    .fixedSize()
                }
            }
            if profile.kind == .devspace && profile.lockedContext == nil {
                Label("Run and Stop are refused until a context is set.", systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(Tone.warn.text)
            } else if let context = profile.lockedContext, !RunPlanner.isValidKubeName(context) {
                Label("Use the context name as kubectl lists it.", systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warn.text)
            }
            if profile.kind == .devspace {
                TextField("Namespace", text: optional(\.kubeNamespace), prompt: Text("optional, passed as --namespace"))
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("Kubernetes")
        } footer: {
            Text("Every kubectl, helm, and DevSpace call in the run uses this context, including scripts and hooks, whatever context is current in your shell. Docket puts a file naming it first in KUBECONFIG, passes --kube-context to DevSpace, and stops before the command if kubectl does not report it.")
                .foregroundStyle(.secondary)
        }
        .task { contexts = await app.kubeContexts() }
        Section {
            LabeledContent("Env file") {
                HStack {
                    Text(profile.envFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { if let path = chooseFile() { profile.envFile = path } }
                    if profile.envFile != nil {
                        Button { profile.envFile = nil } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            Picker("Deliver it by", selection: deliveryMode) {
                Text("Setting a variable to its path").tag(DeliveryMode.variable)
                Text("Copying it into the run folder").tag(DeliveryMode.copy)
            }
            switch profile.envFileDelivery {
            case .variable(let name):
                TextField("Variable", text: Binding(get: { name }, set: { profile.envFileDelivery = .variable($0) }), prompt: Text("DEVSPACE_ENV_FILE"))
                    .font(.system(.body, design: .monospaced))
                if !name.isEmpty && !RunPlanner.isValidKey(name) { invalidKey }
            case .copy(let destination):
                TextField("Copy to", text: Binding(get: { destination }, set: { profile.envFileDelivery = .copy(to: $0) }), prompt: Text(".env"))
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("Env file")
        } footer: {
            Text("Keep the file outside your clones. A variable leaves nothing in the checkout. A copy is made only where git ignores it, and an existing file with different contents is never replaced.")
                .foregroundStyle(.secondary)
        }
        Section {
            ForEach(profile.environment) { variable in
                HStack {
                    TextField("NAME", text: field(variable.id, \.key)).font(.system(.body, design: .monospaced)).frame(width: 180)
                    Text("=")
                    TextField("value", text: field(variable.id, \.value)).font(.system(.body, design: .monospaced))
                    Button { profile.environment.removeAll { $0.id == variable.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                if !variable.key.isEmpty && !RunPlanner.isValidKey(variable.key) { invalidKey }
            }
            Button("Add Variable") { profile.environment.append(EnvVar(key: "", value: "")) }
        } header: {
            Text("Variables")
        } footer: {
            Text("Placeholders in the command and values: {path} (the checkout), {number}, {repo}, and {branch} (same-repository PRs only). Values are used as literal text. These are saved in Docket's preferences, so put secrets in the env file instead.")
                .foregroundStyle(.secondary)
        }
    }

    /// A variable's field, looked up by ID: a text field can write back after its row is deleted,
    /// and then there is nothing to update.
    private func field(_ id: UUID, _ keyPath: WritableKeyPath<EnvVar, String>) -> Binding<String> {
        let profile = $profile
        return Binding(get: { profile.wrappedValue.environment.first { $0.id == id }?[keyPath: keyPath] ?? "" },
                       set: { value in
                           guard let index = profile.wrappedValue.environment.firstIndex(where: { $0.id == id }) else { return }
                           profile.wrappedValue.environment[index][keyPath: keyPath] = value
                       })
    }

    private var invalidKey: some View {
        Label("Use letters, digits, and underscores, not starting with a digit.", systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warn.text)
    }

    private enum DeliveryMode: Hashable { case variable, copy }

    private var deliveryMode: Binding<DeliveryMode> {
        Binding(get: {
            if case .variable = profile.envFileDelivery { return .variable }
            return .copy
        }, set: { mode in
            switch mode {
            case .variable: if case .copy = profile.envFileDelivery { profile.envFileDelivery = .variable(profile.kind == .devspace ? "DEVSPACE_ENV_FILE" : "") }
            case .copy: if case .variable = profile.envFileDelivery { profile.envFileDelivery = .copy(to: ".env") }
            }
        })
    }

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url.map { Safety.canonicalPath($0.path) } : nil
    }
}
