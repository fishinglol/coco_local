import SwiftUI

// MARK: - Markdown renderer for chat assistant messages

/// Parsed blocks and inline text, kept per message text: switching rooms rebuilds bubbles, and parsing
/// Markdown again for each one was what made the switch stutter.
private enum MarkdownCache {
    final class Blocks { let value: [MDBlock]; init(_ v: [MDBlock]) { value = v } }
    final class Inline { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    static let blocks: NSCache<NSString, Blocks> = { let c = NSCache<NSString, Blocks>(); c.countLimit = 300; return c }()
    static let inline: NSCache<NSString, Inline> = { let c = NSCache<NSString, Inline>(); c.countLimit = 2000; return c }()
}

struct ChatMarkdownView: View {
    let markdown: String

    private var blocks: [MDBlock] {
        if let hit = MarkdownCache.blocks.object(forKey: markdown as NSString) { return hit.value }
        let parsed = ChatMarkdown.parse(markdown)
        MarkdownCache.blocks.setObject(MarkdownCache.Blocks(parsed), forKey: markdown as NSString)
        return parsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let safe = safeWebURL(url.absoluteString) else { return .discarded }
            NSWorkspace.shared.open(safe)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineAttributed(text))
                .font(.system(size: level <= 2 ? 14 : 13, weight: level <= 2 ? .bold : .semibold))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#B0B5BE"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .codeBlock(_, let code):
            HStack(alignment: .top) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#C8CDD4"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: code)
            }
            .padding(10)
            .background(Color(hex: "#0D0E12"))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))

        case .listItem(let prefix, let text, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text(prefix)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(minWidth: prefix.count > 2 ? 20 : 10, alignment: .leading)
                Text(inlineAttributed(text))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#B0B5BE"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color(hex: "#4B5563"))
                    .frame(width: 2)
                    .clipShape(Capsule())
                Text(inlineAttributed(text))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#8A8F98"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case .rule:
            Divider().opacity(0.3)
        }
    }

    /// CommonMark refuses `**bold**` when the closing `**` follows punctuation and precedes a letter, which is
    /// the normal case in Thai (no spaces): the asterisks then show up literally. Bold is split on `**` here
    /// first, the rest (code, links, italics) still goes through the Markdown parser.
    private func inlineAttributed(_ text: String) -> AttributedString {
        if let hit = MarkdownCache.inline.object(forKey: text as NSString) { return hit.value }
        let out = buildInline(text)
        MarkdownCache.inline.setObject(MarkdownCache.Inline(out), forKey: text as NSString)
        return out
    }

    private func buildInline(_ text: String) -> AttributedString {
        let parts = text.components(separatedBy: "**")
        guard parts.count >= 3, parts.count % 2 == 1 else { return parseInline(text) }
        var out = AttributedString()
        for (i, part) in parts.enumerated() {
            var seg = parseInline(part)
            if i % 2 == 1 {
                let runs = seg.runs.map { ($0.range, $0.inlinePresentationIntent) }
                for (range, intent) in runs {
                    seg[range].inlinePresentationIntent = (intent ?? []).union(.stronglyEmphasized)
                }
            }
            out += seg
        }
        return out
    }

    private func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Copy button

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundColor(copied ? Color(hex: "#22C55E") : Color(hex: "#6B7079"))
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
