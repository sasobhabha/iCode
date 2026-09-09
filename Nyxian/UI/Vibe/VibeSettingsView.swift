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

struct VibeSettingsView: View {
    @State private var serverURL: String = VibeAgentSettings.serverURL
    @State private var apiKey: String = VibeAgentSettings.apiKey
    @State private var model: String = VibeAgentSettings.model
    @State private var autoApprove: Bool = VibeAgentSettings.autoApproveEdits
    @State private var maxSteps: Double = Double(VibeAgentSettings.maxSteps)

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSucceeded = false

    @Environment(\.dismiss) private var dismiss

    private let presets: [(name: String, url: String, model: String)] = [
        (name: "Google Gemini", url: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-3.5-flash-lite"),
        (name: "Groq — GPT-OSS 120B", url: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b"),
        (name: "NVIDIA NIM — Kimi K3", url: "https://integrate.api.nvidia.com/v1", model: "moonshotai/kimi-k3"),
        (name: "LM Studio (on this Mac/PC)", url: "http://127.0.0.1:1234/v1", model: "local-model"),
        (name: "Ollama", url: "http://127.0.0.1:11434/v1", model: "qwen2.5-coder:7b")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://127.0.0.1:1234/v1", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (optional for local servers)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model name", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("OpenAI-compatible server")
                } footer: {
                    Text("Defaults to Google Gemini (gemini-3.5-flash-lite). If it fails, the agent automatically falls back to Groq (openai/gpt-oss-120b), then NVIDIA NIM (moonshotai/kimi-k3). Any OpenAI-compatible server also works: LM Studio or Ollama on your computer (same Wi-Fi), or any hosted provider.")
                }

                Section("Quick presets") {
                    ForEach(presets, id: \.name) { preset in
                        Button {
                            serverURL = preset.url
                            model = preset.model
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Text(preset.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if serverURL == preset.url {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("Auto-approve edits", isOn: $autoApprove)
                    Stepper(value: $maxSteps, in: 2...24, step: 2) {
                        HStack {
                            Text("Max reasoning steps")
                            Spacer()
                            Text("\(Int(maxSteps))")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("Auto-approve applies AI edits immediately without showing diffs. With it off, every file change waits for your approval with a diff preview.")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text("Test connection")
                        }
                    }
                    .disabled(isTesting || serverURL.isEmpty)

                    if let result = testResult {
                        Label(result, systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(testSucceeded ? .green : .red)
                    }
                } footer: {
                    Text("Sends a tiny chat request to verify the URL, key and model name.")
                }
            }
            .navigationTitle("AI Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        VibeAgentSettings.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        VibeAgentSettings.apiKey = apiKey
        VibeAgentSettings.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "local-model" : model.trimmingCharacters(in: .whitespacesAndNewlines)
        VibeAgentSettings.autoApproveEdits = autoApprove
        VibeAgentSettings.maxSteps = Int(maxSteps)
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        save()

        guard let testURL = URL(string: VibeAgentSettings.serverURL.appending("/chat/completions")) else {
            testSucceeded = false
            testResult = "Invalid server URL."
            return
        }

        var request = URLRequest(url: testURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = VibeAgentSettings.apiKey
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "model": VibeAgentSettings.model,
            "messages": [["role": "user", "content": "Reply with the single word: ready"]],
            "max_tokens": 8,
            "stream": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isTesting = false
                if let error = error {
                    testSucceeded = false
                    testResult = error.localizedDescription
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    testSucceeded = false
                    testResult = "No response."
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    testSucceeded = false
                    let body = data.flatMap { String(data: $0, encoding: .utf8) }
                    let detail = body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                        .flatMap { $0["error"] as? [String: Any] }
                        .flatMap { $0["message"] as? String }
                    testResult = detail ?? "HTTP \(http.statusCode)"
                    return
                }
                testSucceeded = true
                testResult = "Connected to \(VibeAgentSettings.model)."
            }
        }.resume()
    }
}
