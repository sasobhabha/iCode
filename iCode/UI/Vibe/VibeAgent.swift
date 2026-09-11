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

import Foundation
import UIKit

// MARK: - Settings

/// Global user settings for the vibecoding feature.
@objc class VibeAgentSettings: NSObject {
    static let serverURLKey = "VibeServerURL"
    static let apiKeyKey = "VibeAPIKey"
    static let modelKey = "VibeModel"
    static let autoApproveKey = "VibeAutoApproveEdits"
    static let maxStepsKey = "VibeMaxSteps"

    /// URL of an OpenAI-compatible chat/completions endpoint.
    /// Works with Google Gemini, NVIDIA NIM, Groq, local runtimes (LM Studio,
    /// Ollama, llamafile) as well as any other OpenAI-compatible provider.
    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: serverURLKey) ?? VibeSecrets.defaultServerURL }
        set { UserDefaults.standard.set(newValue, forKey: serverURLKey) }
    }

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? VibeSecrets.defaultAPIKey }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? VibeSecrets.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// Ordered fallback chain used when the primary provider fails.
    static let fallbackProviders: [(name: String, url: String, key: String, model: String)] = VibeSecrets.fallbackProviders

    static var autoApproveEdits: Bool {
        get { UserDefaults.standard.object(forKey: autoApproveKey) == nil ? false : UserDefaults.standard.bool(forKey: autoApproveKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoApproveKey) }
    }

    static var maxSteps: Int {
        get {
            let raw = UserDefaults.standard.object(forKey: maxStepsKey) == nil ? 10 : UserDefaults.standard.integer(forKey: maxStepsKey)
            return max(2, min(24, raw))
        }
        set { UserDefaults.standard.set(max(2, min(24, newValue)), forKey: maxStepsKey) }
    }
}

// MARK: - Tool model

enum VibeToolName: String, CaseIterable {
    case listProjectFiles = "list_project_files"
    case readFile = "read_file"
    case editFile = "edit_file"
    case createFile = "create_file"
    case deletePath = "delete_path"
    case buildProject = "build_project"
}

struct VibeToolCall {
    let id: String
    let name: VibeToolName
    let arguments: [String: String]
    /// Gemini 3 thought signature — must be echoed back on the assistant
    /// tool-call message for the next round to be accepted.
    var thoughtSignature: String?
}

// MARK: - Transcript

enum VibeMessageRole: String, Codable {
    case user
    case assistant
    case tool
    case system
}

final class VibeTranscriptMessage: Codable {
    let id: UUID
    let role: VibeMessageRole
    var text: String
    var toolName: String?
    var approved: Bool?

    init(role: VibeMessageRole, text: String, toolName: String? = nil, approved: Bool? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.toolName = toolName
        self.approved = approved
    }
}

/// A saved chat session for one project (path is relative to the project folder).
struct VibeSession: Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var messages: [VibeTranscriptMessage]

    static func sessionsDirectory(for projectURL: URL) -> URL {
        return projectURL.appendingPathComponent("Config/VibeChat", isDirectory: true)
    }

    static func loadSessions(for projectURL: URL) -> [VibeSession] {
        let directory = sessionsDirectory(for: projectURL)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(VibeSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func save(to projectURL: URL) {
        let directory = Self.sessionsDirectory(for: projectURL)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        }
    }

    static func remove(sessionID: UUID, in projectURL: URL) {
        try? FileManager.default.removeItem(at: sessionsDirectory(for: projectURL).appendingPathComponent("\(sessionID.uuidString).json"))
    }
}

// MARK: - Edit approval handling

enum VibePendingDecision {
    case approved
    case denied
}

/// The engine hands every pending file mutation to the delegate. The delegate
/// (usually the chat view controller) shows a diff card and calls back with the
/// user's decision. When `VibeAgentSettings.autoApproveEdits` is on the engine
/// short-circuits and applies immediately.
@MainActor protocol VibeAgentDelegate: AnyObject {
    func vibeAgent(_ agent: VibeAgent, requestsApprovalForChange change: VibeFileChange, completion: @escaping (VibePendingDecision) -> Void)
    func vibeAgent(_ agent: VibeAgent, willRunTool tool: VibeToolName, detail: String)
    func vibeAgent(_ agent: VibeAgent, didFinishTool tool: VibeToolName)
    func vibeAgent(_ agent: VibeAgent, didEmitStreamDelta delta: String)
    func vibeAgent(_ agent: VibeAgent, didEmitReasoningDelta delta: String)
    func vibeAgent(_ agent: VibeAgent, didSwitchToProvider name: String)
    func vibeAgentDidFinishResponse(_ agent: VibeAgent)
    func vibeAgent(_ agent: VibeAgent, didFailWithError message: String)
}

// MARK: - Workspace

/// All file system operations the AI may perform, constrained to one project folder.
final class VibeWorkspace {
    let project: NXProject

    init(project: NXProject) {
        self.project = project
    }

    var rootPath: String { project.url.path }

    private func resolveAllowed(_ relativePath: String) -> URL? {
        let trimmed = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }

        var candidate: URL
        if trimmed.hasPrefix("/") {
            // Absolute paths are accepted only when they resolve inside the project.
            candidate = URL(fileURLWithPath: (trimmed as NSString).standardizingPath)
        } else {
            candidate = project.url.appendingPathComponent(trimmed)
        }

        let rootString = project.url.standardizedFileURL.path
        let candidateString = candidate.standardizedFileURL.path
        guard candidateString.hasPrefix(rootString + "/") || candidateString == rootString else {
            return nil
        }
        return candidate
    }

    func relativePath(for url: URL) -> String {
        let root = project.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    func listFiles() -> [String] {
        var result: [String] = []
        let ignoredDirectories: Set<String> = ["Config", "Resources", ".git", "build"]
        let enumerator = FileManager.default.enumerator(at: project.url, includingPropertiesForKeys: [.isDirectoryKey])
        while let element = enumerator?.nextObject() {
            let url = element as! URL
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasSuffix(".o") || name.hasSuffix(".tmp") { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                if ignoredDirectories.contains(name) {
                    enumerator?.skipDescendants()
                }
                result.append(relativePath(for: url) + "/")
            } else {
                result.append(relativePath(for: url))
            }
        }
        return result.sorted()
    }

    func readFile(_ relativePath: String) throws -> String {
        guard let url = resolveAllowed(relativePath) else {
            throw NSError(domain: "VibeWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path is outside of the project: \(relativePath)"])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func existingContent(of relativePath: String) -> String? {
        guard let url = resolveAllowed(relativePath), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func write(content: String, to relativePath: String) throws {
        guard let fileURL = resolveAllowed(relativePath) else {
            throw NSError(domain: "VibeWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path is outside of the project: \(relativePath)"])
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func delete(_ relativePath: String) throws {
        guard let url = resolveAllowed(relativePath), FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "VibeWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path not found: \(relativePath)"])
        }
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - File change proposals

struct VibeFileChange {
    enum Kind {
        case create
        case modify
        case delete
    }

    let kind: Kind
    let path: String
    let oldContent: String?
    let newContent: String?
}

// MARK: - OpenAI-compatible client

struct VibeChatAPIError: Error {
    let message: String
}

final class VibeChatClient {
    struct PendingResult {
        var content: String
        var toolCalls: [VibeToolCall]
    }

    struct Provider {
        let name: String
        let url: String
        let key: String
        let model: String

        static func primary() -> Provider {
            Provider(name: "Primary", url: VibeAgentSettings.serverURL, key: VibeAgentSettings.apiKey, model: VibeAgentSettings.model)
        }

        static func fallbacks() -> [Provider] {
            return VibeAgentSettings.fallbackProviders.map {
                Provider(name: $0.name, url: $0.url, key: $0.key, model: $0.model)
            }
        }
    }

    private var streamingTask: URLSessionDataTask?

    func cancel() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    private static func endpointURL(forServerURL serverURL: String) throws -> URL {
        var string = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasSuffix("/") { string.removeLast() }
        if string.hasSuffix("/chat/completions") {
            // already the full endpoint
        } else if string.hasSuffix("/v1") {
            string += "/chat/completions"
        } else {
            string += "/v1/chat/completions"
        }
        guard let url = URL(string: string) else {
            throw VibeChatAPIError(message: "Invalid server URL: \(string)")
        }
        return url
    }

    func stream(provider: Provider,
                models: [[String: Any]],
                onDelta: @escaping (String) -> Void,
                onReasoningDelta: @escaping (String) -> Void,
                completion: @escaping (Result<PendingResult, VibeChatAPIError>) -> Void) {
        do {
            let request = try makeRequest(provider: provider, models: models)
            var buffered = ""
            var sseBuffer = Data()
            var completed = false
            var toolCallAccumulators: [Int: (id: String, name: String, arguments: String, signature: String?)] = [:]

            // Invokes completion exactly once and tears the session down.
            var currentSession: URLSession?
            let finishOnce: (Result<PendingResult, VibeChatAPIError>) -> Void = { result in
                guard !completed else { return }
                completed = true
                currentSession?.finishTasksAndInvalidate()
                completion(result)
            }

            func buildToolCalls() -> [VibeToolCall] {
                return toolCallAccumulators.values.compactMap { accumulator in
                    guard let name = VibeToolName(rawValue: accumulator.name) else { return nil }
                    let arguments = (try? JSONSerialization.jsonObject(with: Data(accumulator.arguments.utf8))) as? [String: Any] ?? [:]
                    let stringArguments = arguments.mapValues { value -> String in
                        if let string = value as? String { return string }
                        return (try? JSONSerialization.data(withJSONObject: [value])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    }
                    return VibeToolCall(id: accumulator.id.isEmpty ? UUID().uuidString : accumulator.id, name: name, arguments: stringArguments, thoughtSignature: accumulator.signature)
                }
            }

            let delegate = VibeStreamDelegate(onData: { data in
                // Buffer across packets and process every complete SSE line.
                sseBuffer.append(data)
                while let newline = sseBuffer.firstIndex(of: 0x0A) {
                    let lineData = sseBuffer.subdata(in: sseBuffer.startIndex..<newline)
                    sseBuffer.removeSubrange(sseBuffer.startIndex...newline)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let body = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if body.isEmpty || body == "[DONE]" { continue }
                    guard let chunk = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { continue }

                    if let errorObject = chunk["error"] as? [String: Any] {
                        let message = (errorObject["message"] as? String) ?? "The server reported an error."
                        finishOnce(.failure(VibeChatAPIError(message: message)))
                        return
                    }

                    guard let choices = chunk["choices"] as? [[String: Any]], let choice = choices.first else { continue }

                    if let delta = choice["delta"] as? [String: Any] {
                        let reasoningRaw = delta["reasoning_content"] ?? delta["reasoning"]
                        if let reasoning = reasoningRaw as? String, !reasoning.isEmpty {
                            onReasoningDelta(reasoning)
                        }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            buffered += content
                            onDelta(content)
                        }
                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for call in toolCalls {
                                let index = (call["index"] as? Int) ?? toolCallAccumulators.count
                                var accumulator = toolCallAccumulators[index] ?? ("", "", "", nil)
                                if let id = call["id"] as? String, !id.isEmpty { accumulator.id = id }
                                if let extra = call["extra_content"] as? [String: Any],
                                   let google = extra["google"] as? [String: Any],
                                   let signature = google["thought_signature"] as? String, !signature.isEmpty {
                                    accumulator.signature = signature
                                }
                                if let function = call["function"] as? [String: Any] {
                                    if let name = function["name"] as? String, !name.isEmpty { accumulator.name = name }
                                    if let args = function["arguments"] as? String { accumulator.arguments += args }
                                }
                                toolCallAccumulators[index] = accumulator
                            }
                        }
                    }
                }
            }, completionHandler: { error in
                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        if buffered.isEmpty && toolCallAccumulators.isEmpty {
                            finishOnce(.failure(VibeChatAPIError(message: "The request was cancelled.")))
                        } else {
                            finishOnce(.success(PendingResult(content: buffered, toolCalls: buildToolCalls())))
                        }
                        return
                    }
                    finishOnce(.failure(VibeChatAPIError(message: error.localizedDescription)))
                    return
                }

                let toolCalls = buildToolCalls()
                if buffered.isEmpty && toolCalls.isEmpty {
                    finishOnce(.failure(VibeChatAPIError(message: "The model returned an empty response.")))
                    return
                }

                finishOnce(.success(PendingResult(content: buffered, toolCalls: toolCalls)))
            })

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 900
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            currentSession = session
            streamingTask = session.dataTask(with: request)
            streamingTask?.resume()
        } catch {
            completion(.failure((error as? VibeChatAPIError) ?? VibeChatAPIError(message: error.localizedDescription)))
        }
    }

    private func makeRequest(provider: Provider, models: [[String: Any]]) throws -> URLRequest {
        var request = URLRequest(url: try Self.endpointURL(forServerURL: provider.url))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let key = provider.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": provider.model,
            "messages": models,
            "tools": Self.toolSchema,
            "stream": true,
            "max_tokens": 16384,
            "reasoning_effort": "low"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static let toolSchema: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": VibeToolName.listProjectFiles.rawValue,
                "description": "List every file and folder in the current project, relative to the project root.",
                "parameters": ["type": "object", "properties": [:], "required": []]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": VibeToolName.readFile.rawValue,
                "description": "Read the full text content of a project file.",
                "parameters": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Path relative to the project root"]],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": VibeToolName.editFile.rawValue,
                "description": "Replace an exact occurrence of oldText with newText inside a project file. The oldText must match the file content exactly, including indentation. Keep the replacement as small as possible.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Path relative to the project root"],
                        "oldText": ["type": "string", "description": "Exact existing text to replace"],
                        "newText": ["type": "string", "description": "Replacement text"],
                        "replaceAll": ["type": "boolean", "description": "Replace every occurrence instead of only the first one (default false)"]
                    ],
                    "required": ["path", "oldText", "newText"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": VibeToolName.createFile.rawValue,
                "description": "Create a new file with the given content (or overwrite an existing file entirely with new content).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Path relative to the project root"],
                        "content": ["type": "string", "description": "Full file content"]
                    ],
                    "required": ["path", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": VibeToolName.deletePath.rawValue,
                "description": "Delete a file (or an empty folder) from the project.",
                "parameters": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Path relative to the project root"]],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": VibeToolName.buildProject.rawValue,
                "description": "Compile the project on device and report back every compiler error and warning with file, line and message. Call this after finishing a set of edits.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "run": ["type": "boolean", "description": "Also launch the app after a successful build"]
                    ],
                    "required": []
                ]
            ]
        ]
    ]
}

private extension Data {
    func dropPrefix(_ prefix: Int) -> Data {
        return count > prefix ? suffix(from: index(startIndex, offsetBy: prefix)) : Data()
    }
}

/// Bridges URLSession streaming callbacks into a single handler.
final class VibeStreamDelegate: NSObject, URLSessionDataDelegate {
    private let onData: (Data) -> Void
    private let completionHandler: (Error?) -> Void

    init(onData: @escaping (Data) -> Void, completionHandler: @escaping (Error?) -> Void) {
        self.onData = onData
        self.completionHandler = completionHandler
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completionHandler(error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            DispatchQueue.main.async {
                self.completionHandler(VibeChatAPIError(message: "Server returned HTTP \(http.statusCode) — check the server URL and API key."))
            }
            return
        }
        completionHandler(.allow)
    }
}

// MARK: - Engine

final class VibeAgent {
    let workspace: VibeWorkspace
    weak var delegate: VibeAgentDelegate?

    private(set) var isRunning = false
    private var runGeneration = 0
    private let client = VibeChatClient()

    init(workspace: VibeWorkspace) {
        self.workspace = workspace
    }

    func cancel() {
        guard isRunning else { return }
        runGeneration += 1
        client.cancel()
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.vibeAgent(self, didFailWithError: "Stopped.")
        }
    }

    func run(userMessage: String, history: [VibeTranscriptMessage]) {
        guard !isRunning else { return }
        isRunning = true
        runGeneration += 1
        let generation = runGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var models = Self.modelMessages(
                userMessage: userMessage,
                history: history,
                systemPrompt: Self.systemPrompt(
                    projectName: workspace.project.projectConfig.displayName ?? "Project",
                    language: "Swift / Objective-C / C / C++",
                    interface: "SwiftUI or UIKit",
                    kind: "on-device iOS project"
                )
            )
            var step = 0
            let maxSteps = VibeAgentSettings.maxSteps

            while step < maxSteps {
                if generation != self.runGeneration { return }

                let result = self.performModelRound(messages: models, generation: generation)
                switch result {
                case .failure(let error):
                    if generation != self.runGeneration { return }
                    self.finish(error.message)
                    return

                case .success(let pending):
                    if generation != self.runGeneration { return }

                    if pending.toolCalls.isEmpty {
                        self.finish(nil)
                        return
                    }

                    // Execute every tool call, collect tool results, continue the loop.
                    for call in pending.toolCalls {
                        if generation != self.runGeneration { return }
                        let toolResult = self.executeToolCall(call, generation: generation)
                        if case .abort(let message) = toolResult.outcome {
                            self.finish(message)
                            return
                        }
                        var toolCallPayload: [String: Any] = [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name.rawValue,
                                "arguments": Self.jsonString(from: call.arguments)
                            ]
                        ]
                        if let signature = call.thoughtSignature, !signature.isEmpty {
                            toolCallPayload["extra_content"] = ["google": ["thought_signature": signature]]
                        }
                        models.append([
                            "role": "assistant",
                            "content": pending.content.isEmpty ? "" : pending.content,
                            "tool_calls": [toolCallPayload]
                        ])
                        models.append([
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": toolResult.report
                        ])
                    }

                    step += 1
                }
            }

            self.finish("Reached the maximum number of reasoning steps for this request. Ask me to continue if I ran out of time.")
        }
    }

    private func finish(_ message: String?) {
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let message = message, !message.isEmpty, message != "__cancelled__" {
                self.delegate?.vibeAgent(self, didFailWithError: message)
            } else {
                self.delegate?.vibeAgentDidFinishResponse(self)
            }
        }
    }

    private func performModelRound(messages: [[String: Any]], generation: Int) -> Result<VibeChatClient.PendingResult, VibeChatAPIError> {
        var providers: [VibeChatClient.Provider] = [.primary()]
        providers.append(contentsOf: VibeChatClient.Provider.fallbacks())

        var lastError: VibeChatAPIError?
        for (index, provider) in providers.enumerated() {
            if generation != self.runGeneration { return .failure(VibeChatAPIError(message: "__cancelled__")) }

            if index > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.vibeAgent(self, didSwitchToProvider: provider.name)
                }
            }

            let result = self.streamOnce(provider: provider, messages: messages, generation: generation)
            switch result {
            case .success:
                return result
            case .failure(let error):
                if error.message == "__cancelled__" { return result }
                lastError = error
            }
        }
        return .failure(lastError ?? VibeChatAPIError(message: "All providers failed."))
    }

    private func streamOnce(provider: VibeChatClient.Provider, messages: [[String: Any]], generation: Int) -> Result<VibeChatClient.PendingResult, VibeChatAPIError> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<VibeChatClient.PendingResult, VibeChatAPIError>!

        self.client.stream(provider: provider, models: messages, onDelta: { [weak self] delta in
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.vibeAgent(self, didEmitStreamDelta: delta)
            }
        }, onReasoningDelta: { [weak self] delta in
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.vibeAgent(self, didEmitReasoningDelta: delta)
            }
        }, completion: { result in
            outcome = result
            semaphore.signal()
        })

        if semaphore.wait(timeout: .now() + 420) == .timedOut {
            self.client.cancel()
            return .failure(VibeChatAPIError(message: "\(provider.name) took too long to respond."))
        }

        if generation != self.runGeneration, outcome != nil {
            if case .success = outcome {
                return .failure(VibeChatAPIError(message: "__cancelled__"))
            }
        }
        return outcome
    }

    private enum ToolOutcome {
        case ok
        case abort(String)
    }

    private struct ToolExecution {
        var report: String
        var outcome: ToolOutcome
    }

    private func executeToolCall(_ call: VibeToolCall, generation: Int) -> ToolExecution {
        let path = call.arguments["path"] ?? ""

        func notifyStart(_ detail: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.vibeAgent(self, willRunTool: call.name, detail: detail)
            }
        }

        func notifyEnd() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.vibeAgent(self, didFinishTool: call.name)
            }
        }

        defer { notifyEnd() }

        switch call.name {
        case .listProjectFiles:
            notifyStart("Listing project files")
            let files = workspace.listFiles()
            let report = files.isEmpty ? "The project is empty." : "Project files:\n" + files.joined(separator: "\n")
            return ToolExecution(report: report, outcome: .ok)

        case .readFile:
            notifyStart("Reading \(path)")
            do {
                let content = try workspace.readFile(path)
                let truncated = content.count > 24000 ? String(content.prefix(24000)) + "\n… (truncated)" : content
                return ToolExecution(report: truncated, outcome: .ok)
            } catch {
                return ToolExecution(report: "ERROR: \(error.localizedDescription)", outcome: .ok)
            }

        case .editFile:
            notifyStart("Editing \(path)")
            guard let oldText = call.arguments["oldText"], let newText = call.arguments["newText"] else {
                return ToolExecution(report: "ERROR: editFile requires path, oldText and newText.", outcome: .ok)
            }
            let replaceAll = (call.arguments["replaceAll"] ?? "false").lowercased() == "true"
            guard var content = workspace.existingContent(of: path) else {
                return ToolExecution(report: "ERROR: could not read file \(path). Use create_file if it is new.", outcome: .ok)
            }
            guard content.contains(oldText) else {
                return ToolExecution(report: "ERROR: oldText was not found in \(path). Read the file again and retry with an exact match.", outcome: .ok)
            }
            if replaceAll {
                content = content.replacingOccurrences(of: oldText, with: newText)
            } else {
                guard let range = content.range(of: oldText) else {
                    return ToolExecution(report: "ERROR: oldText was not found in \(path).", outcome: .ok)
                }
                content.replaceSubrange(range, with: newText)
            }
            return approveAndWrite(change: VibeFileChange(kind: .modify, path: path, oldContent: workspace.existingContent(of: path), newContent: content), generation: generation)

        case .createFile:
            notifyStart("Creating \(path)")
            guard let newContent = call.arguments["content"] else {
                return ToolExecution(report: "ERROR: createFile requires path and content.", outcome: .ok)
            }
            let existed = workspace.existingContent(of: path) != nil
            return approveAndWrite(change: VibeFileChange(kind: existed ? .modify : .create, path: path, oldContent: workspace.existingContent(of: path), newContent: newContent), generation: generation)

        case .deletePath:
            notifyStart("Deleting \(path)")
            return approveAndWrite(change: VibeFileChange(kind: .delete, path: path, oldContent: workspace.existingContent(of: path), newContent: nil), generation: generation)

        case .buildProject:
            notifyStart("Building project")
            return executeBuild(run: (call.arguments["run"] ?? "false").lowercased() == "true", generation: generation)
        }
    }

    private func approveAndWrite(change: VibeFileChange, generation: Int) -> ToolExecution {
        var decision: VibePendingDecision = VibeAgentSettings.autoApproveEdits ? .approved : .denied

        if !VibeAgentSettings.autoApproveEdits {
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.sync { [weak self] in
                guard let self = self else {
                    semaphore.signal()
                    return
                }
                self.delegate?.vibeAgent(self, requestsApprovalForChange: change) { userDecision in
                    decision = userDecision
                    semaphore.signal()
                }
            }
            _ = semaphore.wait(timeout: .distantFuture)
        }

        if generation != runGeneration {
            return ToolExecution(report: "Request was cancelled by the user.", outcome: .abort("__cancelled__"))
        }

        switch decision {
        case .denied:
            return ToolExecution(report: "The user declined this change. Continue without it and briefly acknowledge that \(change.path) was left untouched.", outcome: .ok)

        case .approved:
            do {
                switch change.kind {
                case .create, .modify:
                    try workspace.write(content: change.newContent ?? "", to: change.path)
                case .delete:
                    try workspace.delete(change.path)
                }
                Self.notifyFileMutated(path: workspace.relativePath(for: workspace.project.url.appendingPathComponent(change.path)))
                let verb: String
                switch change.kind {
                case .create: verb = "Created"
                case .modify: verb = "Modified"
                case .delete: verb = "Deleted"
                }
                return ToolExecution(report: "\(verb) \(change.path).", outcome: .ok)
            } catch {
                return ToolExecution(report: "ERROR writing \(change.path): \(error.localizedDescription)", outcome: .ok)
            }
        }
    }

    private func executeBuild(run: Bool, generation: Int) -> ToolExecution {
        let semaphore = DispatchSemaphore(value: 0)
        var report = ""

        DispatchQueue.main.sync { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            Self.saveAllDocuments {
                let project = self.workspace.project

                NXBuilder.buildProject(withProject: project, buildType: .export) { result, _ in
                    var messages: [String] = []
                    messages.append(result ? "Build succeeded." : "Build failed.")

                    if run && result && project.projectConfig.schemeKind == .app {
                        _ = PEProcessManager.shared().spawnProcess(withBundleIdentifier: project.projectConfig.bundleid, withItems: [:], withKernelSurfaceProcess: nil, doRestartIfRunning: true)
                        messages.append("The app was launched on the home screen.")
                    }

                    let database = DebugDatabase.getDatabase(ofPath: project.cacheURL.appendingPathComponent("debug.json").path)
                    for (_, object) in database.debugObjects {
                        for item in object.debugItems.prefix(40) {
                            let location = item.sourceLocation.isValid.boolValue ? " (line \(item.sourceLocation.line))" : ""
                            let file = (object.title as NSString).lastPathComponent
                            messages.append("\(file)\(location): \(item.message)")
                        }
                    }

                    report = messages.joined(separator: "\n")
                    semaphore.signal()
                }
            }
        }

        _ = semaphore.wait(timeout: .distantFuture)

        if generation != runGeneration {
            return ToolExecution(report: "Request was cancelled by the user.", outcome: .abort("__cancelled__"))
        }

        return ToolExecution(report: report, outcome: .ok)
    }

    // MARK: Helpers

    static func systemPrompt(projectName: String, language: String, interface: String, kind: String) -> String {
        return """
        You are the AI coding assistant embedded inside iCode, an on-device iOS IDE. You are pair-programming with the user on their project "\(projectName)" (type: \(kind), language: \(language), interface: \(interface), built with the iOS 26.5 SDK on device).

        Rules:
        - You can list, read, edit, create and delete files inside this project and run on-device builds using the provided tools. Do not pretend to run commands you cannot.
        - Prefer edit_file with small exact replacements. Only use create_file to add files or rewrite a file entirely.
        - Keep the app conventions: SwiftUI apps start from a `App` struct; UIKit apps use an AppDelegate and SceneDelegate. Projects may use Swift, Objective-C, C, C++ or a mix.
        - When you finish a coherent set of changes, call build_project so the user gets real compiler feedback, then fix errors if any appear.
        - Write complete, compiling code — never leave TODO placeholders unless the user asked for them.
        - Keep prose short and friendly. Summarize what you changed and why in a few sentences at the end.
        """
    }

    static func modelMessages(userMessage: String, history: [VibeTranscriptMessage], systemPrompt: String) -> [[String: Any]] {
        var models: [[String: Any]] = [["role": "system", "content": systemPrompt]]

        for message in history.suffix(24) {
            switch message.role {
            case .user:
                models.append(["role": "user", "content": message.text])
            case .assistant:
                if !message.text.isEmpty {
                    models.append(["role": "assistant", "content": message.text])
                }
            case .tool, .system:
                break
            }
        }

        models.append(["role": "user", "content": userMessage])
        return models
    }

    static func jsonString(from dictionary: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func saveAllDocuments(completion: @escaping () -> Void) {
        NXDocumentManager.shared().saveAll(completion: completion)
    }

    /// Posted after every approved file mutation so open editors can live-reload
    /// and file lists can refresh. The object is the absolute path as String.
    static let fileMutatedNotification = Notification.Name("VibeFileMutated")

    static func notifyFileMutated(path: String) {
        NotificationCenter.default.post(name: fileMutatedNotification, object: path)
    }
}
