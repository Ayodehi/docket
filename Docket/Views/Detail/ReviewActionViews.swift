import GitHubKit
import ReviewCore
import SwiftUI

/// The PR an action applies to, from Docket's own data. The title is shown separately as quoted
/// text so a crafted title cannot read as part of the action.
private struct ActionTarget: View {
    let pr: PRSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(pr.repo) #\(pr.number)").font(.system(.callout, design: .monospaced))
            Text("“\(pr.title)”").foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Picks reviewers to add. Existing requests stay (the request always adds).
struct RequestReviewersSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pr: PRSnapshot

    @State private var suggestions: [String]?
    @State private var typed: [String] = []
    @State private var selected: Set<String> = []
    @State private var entry = ""
    @State private var entryError: String?
    @State private var busy = false
    @State private var error: String?

    /// People already asked or who are the author; GitHub would reject or ignore them.
    private var excluded: Set<String> {
        Set(pr.reviewers.filter { $0.verdict == .requested }.map { $0.name.lowercased() } + [pr.author.lowercased()])
    }

    private var people: [String] {
        var seen = Set<String>()
        return (typed + (suggestions ?? []) + pr.reviewers.filter { !$0.isTeam }.map(\.name))
            .filter { !excluded.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }

    private var teams: [String] {
        app.requestableTeams(for: pr).filter { !excluded.contains($0.lowercased()) }
    }

    private var chosenUsers: [String] { people.filter(selected.contains) }
    private var chosenTeams: [String] { teams.filter(selected.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Request Reviewers").font(.title3.weight(.semibold))
            ActionTarget(pr: pr)
            Panel(title: "People", trailing: suggestions == nil ? "loading suggestions" : "") {
                if suggestions != nil && people.isEmpty {
                    PanelRow { Text("No suggestions. Add someone by username below.").foregroundStyle(.secondary); Spacer() }
                }
                ForEach(people, id: \.self) { login in
                    PanelRow { Toggle(login, isOn: binding(login)); Spacer() }
                }
                PanelRow {
                    TextField("GitHub username", text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTyped)
                    Button("Add", action: addTyped).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !teams.isEmpty {
                Panel(title: "Your teams") {
                    ForEach(teams, id: \.self) { team in
                        PanelRow { Toggle(team, isOn: binding(team)); Spacer() }
                    }
                }
            }
            if let entryError {
                Label(entryError, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warn.text)
            }
            Divider()
            Text(summary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(Tone.err.text).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Requesting…" : "Request Review", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            suggestions = await app.suggestedReviewers(for: pr)
        }
    }

    private var summary: String {
        let names = chosenUsers + chosenTeams
        guard !names.isEmpty else { return "Choose who to ask. Existing review requests stay." }
        return "Docket will ask \(ListFormatter.localizedString(byJoining: names)) to review \(pr.repo) #\(pr.number) on GitHub. Existing review requests stay."
    }

    private func binding(_ name: String) -> Binding<Bool> {
        Binding(get: { selected.contains(name) }, set: { on in
            if on { selected.insert(name) } else { selected.remove(name) }
        })
    }

    private func addTyped() {
        let login = entry.trimmingCharacters(in: .whitespaces).trimmingPrefix("@").description
        entryError = nil
        guard !login.isEmpty else { return }
        guard ReviewInput.isLogin(login) else {
            entryError = login.contains("/") ? "Teams can only be chosen from Your teams." : ReviewInputError.invalidLogin(login).message
            return
        }
        guard !excluded.contains(login.lowercased()) else {
            entryError = login.lowercased() == pr.author.lowercased() ? "The author cannot review their own PR." : "\(login) is already requested."
            return
        }
        if !people.contains(where: { $0.lowercased() == login.lowercased() }) { typed.append(login) }
        selected.insert(people.first { $0.lowercased() == login.lowercased() } ?? login)
        entry = ""
    }

    private func submit() {
        error = nil
        let action: ReviewAction
        do {
            action = try ReviewAction.makeRequest(pullRequestID: pr.id, users: chosenUsers, teams: chosenTeams)
        } catch let failure as ReviewInputError {
            error = failure.message
            return
        } catch {
            return
        }
        busy = true
        Task {
            do {
                try await app.perform(action, on: pr)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Dismisses one reviewer's approval or change request, with a reason the user types.
struct DismissReviewSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pr: PRSnapshot
    let reviewer: ReviewerState

    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?

    private var what: String { reviewer.opinion == .approved ? "approval" : "change request" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dismiss Review").font(.title3.weight(.semibold))
            ActionTarget(pr: pr)
            Text("Dismiss \(reviewer.name)'s \(what) on \(pr.repo) #\(pr.number)?")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Reason (shown on the pull request)").font(.callout.weight(.medium))
                TextField("Reason", text: $reason, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
            }
            Text("GitHub records the dismissal on the PR with your name and this reason. Branch protection may not allow you to dismiss reviews.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(Tone.err.text).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Dismissing…" : "Dismiss Review", role: .destructive, action: submit)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        error = nil
        guard let reviewID = reviewer.opinionReviewID else { return }
        let action: ReviewAction
        do {
            action = try ReviewAction.makeDismiss(reviewID: reviewID, message: reason)
        } catch let failure as ReviewInputError {
            error = failure.message
            return
        } catch {
            return
        }
        busy = true
        Task {
            do {
                try await app.perform(action, on: pr)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
