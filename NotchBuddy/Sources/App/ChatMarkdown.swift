import Foundation

// MARK: - Markdown block types

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(lang: String, code: String)
    /// prefix: "•" for unordered, "1." / "2." etc for ordered; indent: nesting level (0-based)
    case listItem(prefix: String, text: String, indent: Int)
    case quote(text: String)
    case rule
    /// A pipe table: header cells and body rows (rows are padded to the header's width).
    case table(header: [String], rows: [[String]])
}

// MARK: - Parser (Foundation only)

enum ChatMarkdown {

    static func parse(_ input: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Fenced code block. Like CommonMark: it closes only on a bare fence at least as long as the
            // opening one, so a ```` block can hold ``` lines (an agent showing a file that has code blocks).
            if let fence = fenceOpening(line) {
                let lang = String(line.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !isClosingFence(lines[i], matching: fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(lang: lang, code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            // Pipe table: a row with "|" followed by a separator row like |---|:--:|
            if i + 1 < lines.count, isTableStart(lines, i) {
                let header = tableCells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    var cells = tableCells(lines[i])
                    while cells.count < header.count { cells.append("") }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // ATX heading — MUST have space after the #s
            if line.hasPrefix("#") {
                var level = 0
                var rest = line
                while rest.hasPrefix("#") { level += 1; rest = String(rest.dropFirst()) }
                // Require a space (or end of line) after the hashes
                if rest.hasPrefix(" ") || rest.isEmpty {
                    let text = rest.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { blocks.append(.heading(level: min(level, 6), text: text)) }
                    i += 1
                    continue
                }
                // else fall through to paragraph
            }

            // Horizontal rule
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped == "---" || stripped == "***" || stripped == "___" {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Blockquote
            if stripped.hasPrefix("> ") || stripped == ">" {
                let text = stripped.hasPrefix("> ") ? String(stripped.dropFirst(2)) : ""
                blocks.append(.quote(text: text))
                i += 1
                continue
            }

            // List item — detect indent level by leading spaces, then match marker
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let indent = leadingSpaces / 2
            if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
                let text = String(stripped.dropFirst(2))
                blocks.append(.listItem(prefix: "•", text: text, indent: indent))
                i += 1
                continue
            }
            // Ordered list item
            if let range = stripped.range(of: "^(\\d+)\\.\\s+", options: .regularExpression) {
                let number = String(stripped[..<range.upperBound])
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: ".").first ?? "1"
                let text = String(stripped[range.upperBound...])
                blocks.append(.listItem(prefix: "\(number).", text: text, indent: indent))
                i += 1
                continue
            }

            // Blank line — skip
            if stripped.isEmpty {
                i += 1
                continue
            }

            // Paragraph: accumulate consecutive non-special lines
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextStripped = next.trimmingCharacters(in: .whitespaces)
                if nextStripped.isEmpty { break }
                if next.hasPrefix("#") { break }
                if fenceOpening(next) != nil { break }
                if isTableStart(lines, i) { break }
                if nextStripped.hasPrefix("> ") || nextStripped == ">" { break }
                if nextStripped.hasPrefix("- ") || nextStripped.hasPrefix("* ") || nextStripped.hasPrefix("+ ") { break }
                if nextStripped == "---" || nextStripped == "***" || nextStripped == "___" { break }
                // Break before ordered list items too
                if nextStripped.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil { break }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(text: paragraphLines.joined(separator: "\n")))
        }
        return blocks
    }

    /// "```" / "````" / "~~~" at the start of a line: the fence text itself, nil when the line is not a fence.
    private static func fenceOpening(_ line: String) -> String? {
        for mark in ["`", "~"] {
            let n = line.prefix(while: { String($0) == mark }).count
            if n >= 3 { return String(repeating: mark, count: n) }
        }
        return nil
    }

    private static func isClosingFence(_ line: String, matching fence: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let mark = fence.first, t.count >= fence.count else { return false }
        return t.allSatisfy { $0 == mark }
    }

    private static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|") else { return false }
        let sep = lines[i + 1].trimmingCharacters(in: .whitespaces)
        return sep.contains("-") && sep.contains("|") && sep.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
