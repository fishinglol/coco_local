import SwiftUI
import SwiftMath

// MARK: - Markdown renderer for chat assistant messages

/// Parsed blocks and inline text, kept per message text: switching rooms rebuilds bubbles, and parsing
/// Markdown again for each one was what made the switch stutter.
private enum MarkdownCache {
    final class Blocks { let value: [MDBlock]; init(_ v: [MDBlock]) { value = v } }
    enum Seg { case text(AttributedString), math(NSImage, CGFloat) }
    final class Inline { let value: [Seg]; init(_ v: [Seg]) { value = v } }
    static let blocks: NSCache<NSString, Blocks> = { let c = NSCache<NSString, Blocks>(); c.countLimit = 300; return c }()
    static let inline: NSCache<NSString, Inline> = { let c = NSCache<NSString, Inline>(); c.countLimit = 2000; return c }()
}

@MainActor struct ChatMarkdownView: View {
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
            inlineText((text))
                .font(.system(size: level <= 2 ? 14 : 13, weight: level <= 2 ? .bold : .semibold))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .paragraph(let text):
            inlineText((text))
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
                inlineText((text))
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
                inlineText((text))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#8A8F98"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case .rule:
            Divider().opacity(0.3)

        case .table(let header, let rows):
            // Wide tables scroll sideways instead of squeezing every column.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                            inlineText((h))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(hex: "#F1F2F4"))
                                .frame(minWidth: 56, maxWidth: 200, alignment: .leading)
                        }
                    }
                    Divider().opacity(0.3).gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, c in
                                inlineText((c))
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "#B0B5BE"))
                                    .frame(minWidth: 56, maxWidth: 200, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Color(hex: "#0D0E12"))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    /// CommonMark refuses `**bold**` when the closing `**` follows punctuation and precedes a letter, which is
    /// the normal case in Thai (no spaces): the asterisks then show up literally. Bold is split on `**` here
    /// first, the rest (code, links, italics) still goes through the Markdown parser.
    private func inlineText(_ text: String) -> Text {
        let segs: [MarkdownCache.Seg]
        if let hit = MarkdownCache.inline.object(forKey: text as NSString) {
            segs = hit.value
        } else {
            var images: [(NSImage, CGFloat)] = []
            let source = Self.mathSymbols(text) { latex in
                guard let item = Self.renderMath(latex), images.count < 64 else { return nil }
                images.append(item)
                return Character(UnicodeScalar(0xE000 + images.count - 1)!)
            }
            let attr = buildInline(source)
            var built: [MarkdownCache.Seg] = []
            var start = attr.startIndex
            var i = attr.startIndex
            while i < attr.endIndex {
                let next = attr.index(afterCharacter: i)
                if let v = attr.characters[i].unicodeScalars.first?.value,
                   v >= 0xE000, v < 0xE000 + UInt32(images.count) {
                    if start < i { built.append(.text(AttributedString(attr[start..<i]))) }
                    let item = images[Int(v - 0xE000)]
                    built.append(.math(item.0, item.1))
                    start = next
                }
                i = next
            }
            if start < attr.endIndex { built.append(.text(AttributedString(attr[start..<attr.endIndex]))) }
            segs = built
            MarkdownCache.inline.setObject(MarkdownCache.Inline(segs), forKey: text as NSString)
        }
        return segs.reduce(Text("")) { acc, seg in
            switch seg {
            case .text(let a): return acc + Text(a)
            case .math(let img, let descent):
                return acc + Text(Image(nsImage: img).renderingMode(.template)).baselineOffset(-descent)
            }
        }
    }

    /// LaTeX → image with SwiftMath (drawn black, tinted by the text colour). nil when SwiftMath cannot parse it.
    @MainActor private static func renderMath(_ latex: String) -> (NSImage, CGFloat)? {
        let size: CGFloat = 14
        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = size
        label.labelMode = .display
        _ = label.fittingSize
        guard label.error == nil, let list = label.displayList else { return nil }
        let img = MTMathImage(latex: latex, fontSize: size, textColor: .black, labelMode: .display, textAlignment: .left)
        guard case (nil, let image?) = img.asImage() else { return nil }
        image.isTemplate = true
        return (image, list.descent)
    }

    private static let latexSymbols: [String: String] = [
        "\\rightarrow": "→", "\\to": "→", "\\leftarrow": "←", "\\leftrightarrow": "↔", "\\Rightarrow": "⇒",
        "\\Leftarrow": "⇐", "\\Leftrightarrow": "⇔", "\\uparrow": "↑", "\\downarrow": "↓",
        "\\times": "×", "\\div": "÷", "\\pm": "±", "\\approx": "≈", "\\neq": "≠", "\\leq": "≤",
        "\\geq": "≥", "\\infty": "∞", "\\cdot": "·", "\\checkmark": "✓", "\\ldots": "…", "\\dots": "…",
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\pi": "π", "\\mu": "μ",
        "\\sigma": "σ", "\\lambda": "λ", "\\theta": "θ", "\\Delta": "Δ", "\\sum": "∑", "\\degree": "°",
        "\\phi": "φ", "\\omega": "ω", "\\rho": "ρ", "\\tau": "τ", "\\epsilon": "ε", "\\Sigma": "Σ",
        "\\Omega": "Ω", "\\Phi": "Φ", "\\cdots": "⋯", "\\circ": "°", "\\angle": "∠", "\\perp": "⊥",
        // Function names are plain words once the backslash goes.
        "\\sin": "sin", "\\cos": "cos", "\\tan": "tan", "\\cot": "cot", "\\sec": "sec", "\\csc": "csc",
        "\\log": "log", "\\ln": "ln", "\\exp": "exp", "\\det": "det", "\\min": "min", "\\max": "max",
        "\\lim": "lim",
    ]

    /// The chat has no LaTeX engine, so a `$…$` span is turned into plain text: symbols, `\frac{a}{b}` → `(a)/(b)`,
    /// `\sqrt{x}` → `√x`, `^\circ` → `°`, `^2` → `²`, `\text{…}` → `…`, and a bare `$1$` loses its dollars.
    /// With `render`, a span holding a backslash command is drawn by SwiftMath (the closure returns its placeholder);
    /// otherwise the plain-text conversion is used. A span that still holds an unknown command, and any other
    /// `$` text (prices), is left alone.
    static func mathSymbols(_ text: String, render: ((String) -> Character?)? = nil) -> String {
        guard text.contains("$") else { return text }
        let parts = text.replacingOccurrences(of: "$$", with: "$").components(separatedBy: "$")
        guard parts.count >= 3 else { return text }
        var out = parts[0]
        var i = 1
        while i < parts.count {
            let span = parts[i]
            let closed = i + 1 < parts.count
            if closed, span.contains("\\"), let mark = render?(span) {
                out += String(mark)
            } else if closed, let plain = plainMath(span) {
                out += plain
                i += 1
                if i < parts.count { out += parts[i] }   // text after the closing $
                i += 1
            } else {
                out += "$" + span
                i += 1
            }
        }
        return out
    }

    private static func plainMath(_ span: String) -> String? {
        let isNumber = span.range(of: #"^[0-9]+([.,][0-9]+)?$"#, options: .regularExpression) != nil
        let isScript = span.range(of: #"^\S*[\^_]\S*$"#, options: .regularExpression) != nil
        guard span.contains("\\") || isNumber || isScript else { return nil }
        var s = span
        func sub(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        sub(#"\\(?:text|mathrm|mathbf|mathit|operatorname)\{([^{}]*)\}"#, "$1")
        for _ in 0..<4 {   // nested fractions: innermost first
            sub(#"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, "($1)/($2)")
        }
        sub(#"\\sqrt\{([^{}]*)\}"#, "√($1)")
        sub(#"\^\s*\{?\\circ\}?"#, "°")
        sub(#"\\(?:left|right|,|;|!|quad|qquad)(?![A-Za-z])"#, "")
        // \name → symbol when known
        if let re = try? NSRegularExpression(pattern: #"\\([A-Za-z]+)"#) {
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let cmd = ns.substring(with: m.range)
                result += latexSymbols[cmd] ?? cmd
                last = m.range.location + m.range.length
            }
            s = result + ns.substring(from: last)
        }
        if s.contains("\\") { return nil }
        let sup: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
                                           "7": "⁷", "8": "⁸", "9": "⁹", "n": "ⁿ", "+": "⁺", "-": "⁻"]
        let subs: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
                                            "7": "₇", "8": "₈", "9": "₉"]
        func script(_ marker: String, _ table: [Character: Character]) {
            guard let re = try? NSRegularExpression(pattern: "\\" + marker + #"(?:\{([^{}]*)\}|([A-Za-z0-9]))"#) else { return }
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let g1 = m.range(at: 1), g2 = m.range(at: 2)
                let body = g1.location != NSNotFound ? ns.substring(with: g1) : ns.substring(with: g2)
                result += body.allSatisfy({ table[$0] != nil }) ? String(body.map { table[$0]! })
                                                                 : (marker == "^" ? "^(\(body))" : "_(\(body))")
                last = m.range.location + m.range.length
            }
            s = result + ns.substring(from: last)
        }
        script("^", sup)
        script("_", subs)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s
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
        var out = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // `code` in a sentence: salmon on a soft chip, like Claude's own window.
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].foregroundColor = Color(hex: "#E08A78")
            out[run.range].backgroundColor = Color.white.opacity(0.09)
        }
        return out
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
