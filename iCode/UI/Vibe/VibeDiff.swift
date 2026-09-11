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

// MARK: - Line diff engine

struct VibeDiffLine {
    enum Kind {
        case context
        case added
        case removed
    }

    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

enum VibeDiffer {
    /// Unified diff over lines using an LCS table. Good enough for source files
    /// that a chat model edits; no external dependency required.
    static func diff(old oldContent: String, new newContent: String) -> [VibeDiffLine] {
        let oldLines = oldContent.components(separatedBy: "\n")
        let newLines = newContent.components(separatedBy: "\n")

        let n = oldLines.count
        let m = newLines.count

        // Guard against pathological sizes (binary blobs pasted as text etc.)
        guard n * m < 16_000_000 else {
            return newLines.enumerated().map { (index, line) in
                VibeDiffLine(kind: .added, text: line, oldNumber: nil, newNumber: index + 1)
            }
        }

        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if oldLines[i] == newLines[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var result: [VibeDiffLine] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                result.append(VibeDiffLine(kind: .context, text: oldLines[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(VibeDiffLine(kind: .removed, text: oldLines[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            } else {
                result.append(VibeDiffLine(kind: .added, text: newLines[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            }
        }
        while i < n {
            result.append(VibeDiffLine(kind: .removed, text: oldLines[i], oldNumber: i + 1, newNumber: nil))
            i += 1
        }
        while j < m {
            result.append(VibeDiffLine(kind: .added, text: newLines[j], oldNumber: nil, newNumber: j + 1))
            j += 1
        }

        return collapseCommonTail(result)
    }

    /// A full-file rewrite produced by a model usually leaves the trailing
    /// newline flagged as a change; collapse that noise.
    private static func collapseCommonTail(_ lines: [VibeDiffLine]) -> [VibeDiffLine] {
        guard let last = lines.last, last.kind != .context, last.text.isEmpty else { return lines }
        var result = lines
        result.removeLast()
        return result
    }

    static func summarize(_ lines: [VibeDiffLine]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in lines {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .context: break
            }
        }
        return (added, removed)
    }
}

// MARK: - Diff card view

struct VibeDiffCardView: View {
    let change: VibeFileChange
    let decision: VibePendingDecision?
    let onApprove: (() -> Void)?
    let onDeny: (() -> Void)?

    @State private var expanded: Bool

    init(change: VibeFileChange,
         decision: VibePendingDecision? = nil,
         onApprove: (() -> Void)? = nil,
         onDeny: (() -> Void)? = nil,
         initiallyExpanded: Bool = false) {
        self.change = change
        self.decision = decision
        self.onApprove = onApprove
        self.onDeny = onDeny
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var diffLines: [VibeDiffLine] {
        switch change.kind {
        case .create:
            return VibeDiffer.diff(old: "", new: change.newContent ?? "")
        case .delete:
            return VibeDiffer.diff(old: change.oldContent ?? "", new: "")
        case .modify:
            return VibeDiffer.diff(old: change.oldContent ?? "", new: change.newContent ?? "")
        }
    }

    private var summary: (added: Int, removed: Int) {
        VibeDiffer.summarize(diffLines)
    }

    private var kindLabel: String {
        switch change.kind {
        case .create: return "New file"
        case .modify: return "Modified"
        case .delete: return "Deleted"
        }
    }

    private var kindColor: Color {
        switch change.kind {
        case .create: return .green
        case .modify: return .blue
        case .delete: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: {
                        switch change.kind {
                        case .create: return "plus.square.fill"
                        case .modify: return "pencil.tip.crop.circle.fill"
                        case .delete: return "minus.square.fill"
                        }
                    }())
                    .foregroundStyle(kindColor)

                    VStack(alignment: .leading, spacing: 1) {
                        Text((change.path as NSString).lastPathComponent)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(change.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text("+\(summary.added) −\(summary.removed)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(diffLines.prefix(400).enumerated()), id: \.offset) { _, line in
                            VibeDiffLineView(line: line)
                        }
                        if diffLines.count > 400 {
                            Text("… \(diffLines.count - 400) more lines")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(Color(UIColor.tertiarySystemBackground))
                        }
                    }
                }
                .frame(maxHeight: 260)
                .background(Color(UIColor.secondarySystemBackground))
            }

            if decision == nil, let onApprove = onApprove, let onDeny = onDeny {
                HStack(spacing: 10) {
                    Button {
                        onDeny()
                    } label: {
                        Text("Reject")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button {
                        onApprove()
                    } label: {
                        Label("Apply", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding([.horizontal, .bottom], 12)
            }

            if let decision = decision {
                HStack(spacing: 6) {
                    Image(systemName: decision == .approved ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(decision == .approved ? Color.green : Color.red)
                    Text(decision == .approved ? "Applied" : "Rejected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct VibeDiffLineView: View {
    let line: VibeDiffLine

    private var backgroundColor: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.18)
        case .removed: return Color.red.opacity(0.15)
        case .context: return .clear
        }
    }

    private var accentColor: Color {
        switch line.kind {
        case .added: return Color.green
        case .removed: return Color.red
        case .context: return .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text({
                switch line.kind {
                case .added: return "+"
                case .removed: return "−"
                case .context: return " "
                }
            }())
            .font(.caption.monospaced())
            .foregroundStyle(accentColor.opacity(line.kind == .context ? 0 : 1))
            .frame(width: 14)

            Text({
                switch (line.kind, line.oldNumber, line.newNumber) {
                case (.context, let o?, let n?): return "\(o)   \(n)"
                case (.removed, let o?, _): return "\(o)"
                case (.added, _, let n?): return "    \(n)"
                default: return ""
                }
            }())
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .frame(width: 64, alignment: .trailing)
            .padding(.trailing, 6)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.caption.monospaced())
                .foregroundStyle(line.kind == .context ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .background(backgroundColor)
    }
}

// MARK: - Tool activity card

struct VibeToolActivityView: View {
    let toolName: String
    let detail: String
    let isRunning: Bool

    private var icon: String {
        switch toolName {
        case "list_project_files": return "list.bullet.rectangle.fill"
        case "read_file": return "doc.text.magnifyingglass"
        case "edit_file": return "pencil.and.outline"
        case "create_file": return "plus.square.dashed"
        case "delete_path": return "trash"
        case "build_project": return "hammer.fill"
        default: return "gearshape.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(detail.isEmpty ? toolName : detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if isRunning {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(Capsule())
    }
}
