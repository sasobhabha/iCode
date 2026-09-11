/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

import SwiftUI
import UIKit

// MARK: - View model

@MainActor
final class VibeChatViewModel: ObservableObject {
    @Published var messages: [VibeTranscriptMessage] = []
    @Published var streamingText: String = ""
    @Published var reasoningText: String = ""
    @Published var isRunning: Bool = false
    @Published var activity: [VibeToolActivity] = []
    @Published var pendingChanges: [PendingChange] = []
    @Published var showReasoning: Bool = false

    struct VibeToolActivity: Identifiable {
        let id = UUID()
        var toolName: String
        var detail: String
        var isRunning: Bool
    }

    struct PendingChange: Identifiable {
        let id = UUID()
        let change: VibeFileChange
        let completion: (VibePendingDecision) -> Void
        var decision: VibePendingDecision?
    }

    let project: NXProject
    private var agent: VibeAgent?
    private var session = VibeSession(id: UUID(), title: "New Chat", createdAt: Date(), messages: [])

    init(project: NXProject) {
        self.project = project
    }

    var canSend: Bool { !isRunning }

    var inputHint: String {
        isRunning ? "Working on it…" : "Describe what to build…"
    }

    // MARK: Session persistence

    func loadMostRecentSession() {
        let sessions = VibeSession.loadSessions(for: project.url)
        if let recent = sessions.last {
            session = recent
            messages = recent.messages
        }
    }

    func startNewSession() {
        persistCurrentSession()
        session = VibeSession(id: UUID(), title: "New Chat", createdAt: Date(), messages: [])
        messages = []
        streamingText = ""
        activity = []
        pendingChanges = []
    }

    private func persistCurrentSession() {
        guard messages.contains(where: { $0.role == .user }) else { return }
        if let firstUser = messages.first(where: { $0.role == .user }) {
            session.title = String(firstUser.text.prefix(48))
        }
        session.messages = messages
        session.save(to: project.url)
    }

    // MARK: Sending

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }

        streamingText = ""
        reasoningText = ""
        showReasoning = false
        activity = []
        pendingChanges = []
        messages.append(VibeTranscriptMessage(role: .user, text: text))
        isRunning = true

        let workspace = VibeWorkspace(project: project)
        let agent = VibeAgent(workspace: workspace)
        self.agent = agent
        agent.delegate = self
        agent.run(userMessage: text, history: Array(messages.dropLast()))
    }

    func stop() {
        agent?.cancel()
    }

    // MARK: Approval plumbing (called by the view)

    func decide(_ pending: PendingChange, decision: VibePendingDecision) {
        guard let index = pendingChanges.firstIndex(where: { $0.id == pending.id }) else { return }
        pendingChanges[index].decision = decision
        pending.completion(decision)
    }
}

extension VibeChatViewModel: VibeAgentDelegate {
    func vibeAgent(_ agent: VibeAgent, requestsApprovalForChange change: VibeFileChange, completion: @escaping (VibePendingDecision) -> Void) {
        // Arrives on the main thread (the agent hops for delegate calls).
        pendingChanges.append(PendingChange(change: change, completion: completion, decision: nil))
    }

    func vibeAgent(_ agent: VibeAgent, willRunTool tool: VibeToolName, detail: String) {
        activity.append(VibeToolActivity(toolName: tool.rawValue, detail: detail, isRunning: true))
    }

    func vibeAgent(_ agent: VibeAgent, didFinishTool tool: VibeToolName) {
        if let index = activity.lastIndex(where: { $0.toolName == tool.rawValue && $0.isRunning }) {
            activity[index].isRunning = false
        }
    }

    func vibeAgent(_ agent: VibeAgent, didEmitStreamDelta delta: String) {
        streamingText += delta
    }

    func vibeAgent(_ agent: VibeAgent, didEmitReasoningDelta delta: String) {
        reasoningText += delta
    }

    func vibeAgent(_ agent: VibeAgent, didSwitchToProvider name: String) {
        reasoningText += (reasoningText.isEmpty ? "" : "\n\n") + "— switching to \(name) —\n"
        showReasoning = true
    }

    func vibeAgentDidFinishResponse(_ agent: VibeAgent) {
        finalizeTurn(error: nil)
    }

    func vibeAgent(_ agent: VibeAgent, didFailWithError message: String) {
        finalizeTurn(error: message == "Stopped." ? nil : message, stopped: message == "Stopped.")
    }

    private func finalizeTurn(error: String?, stopped: Bool = false) {
        let streamed = streamingText
        streamingText = ""
        reasoningText = ""
        showReasoning = false

        if !streamed.isEmpty {
            messages.append(VibeTranscriptMessage(role: .assistant, text: streamed))
        }
        if let error = error {
            messages.append(VibeTranscriptMessage(role: .assistant, text: "⚠️ " + error))
        }
        if streamed.isEmpty && error == nil {
            messages.append(VibeTranscriptMessage(role: .assistant, text: stopped ? "Stopped." : "(no response)"))
        }

        isRunning = false
        persistCurrentSession()
    }
}

// MARK: - Chat view

struct VibeChatView: View {
    @StateObject private var model: VibeChatViewModel
    @State private var input: String = ""
    @State private var showSettings = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    init(project: NXProject) {
        _model = StateObject(wrappedValue: VibeChatViewModel(project: project))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                inputBar
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Vibe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(model.isRunning)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        model.startNewSession()
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .disabled(model.isRunning)

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                VibeSettingsView()
            }
            .onAppear {
                model.loadMostRecentSession()
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty && !model.isRunning {
                        emptyState
                    }

                    ForEach(model.messages, id: \.id) { message in
                        VibeMessageBubble(message: message)
                            .id(message.id)
                    }

                    ForEach(model.pendingChanges) { pending in
                        VibeDiffCardView(
                            change: pending.change,
                            decision: pending.decision,
                            onApprove: pending.decision == nil ? { model.decide(pending, decision: .approved) } : nil,
                            onDeny: pending.decision == nil ? { model.decide(pending, decision: .denied) } : nil
                        )
                        .id(pending.id)
                    }

                    ForEach(model.activity) { item in
                        VibeToolActivityView(toolName: item.toolName, detail: item.detail, isRunning: item.isRunning)
                            .id(item.id)
                    }

                    if !model.reasoningText.isEmpty && model.isRunning {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    model.showReasoning.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "brain")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Thinking")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(model.showReasoning ? 180 : 0))
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)

                            if model.showReasoning {
                                Text(model.reasoningText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .id("reasoning")
                    }

                    if !model.streamingText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.streamingText)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .id("streaming")
                    }

                    if model.isRunning && model.streamingText.isEmpty && model.activity.isEmpty && model.pendingChanges.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Thinking…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .id("thinking")
                    }
                }
                .padding(14)
            }
            .onChange(of: model.streamingText) { _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: model.reasoningText.count) { _ in
                proxy.scrollTo("reasoning", anchor: .bottom)
            }
            .onChange(of: model.activity.count) { _ in
                withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
            }
            .onChange(of: model.messages.count) { _ in
                withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
            }
            .onChange(of: model.pendingChanges.count) { _ in
                withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Vibecode \(model.project.projectConfig.displayName ?? "your app")")
                .font(.headline)
            Text("Ask for features, fixes or refactors. The assistant can read, edit and build your project right on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if model.isRunning {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    let text = input
                    input = ""
                    model.send(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField(model.inputHint, text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .focused($inputFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Message bubble

struct VibeMessageBubble: View {
    let message: VibeTranscriptMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .tool, .system:
            EmptyView()
        }
    }
}

// MARK: - UIKit wrapper

/// Presents the vibecoding chat as a sheet over the current UI. Used from the
/// UIKit file list and the iPad detail controller.
@objc class VibeChatPresenter: NSObject {
    @objc static func present(from viewController: UIViewController, project: NXProject) {
        let chat = VibeChatView(project: project)
        let hosting = UIHostingController(rootView: chat)
        hosting.modalPresentationStyle = .pageSheet
        if let sheet = hosting.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        viewController.present(hosting, animated: true)
    }
}
