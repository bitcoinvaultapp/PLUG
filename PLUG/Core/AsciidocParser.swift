import Foundation

// MARK: - Lightweight AsciiDoc → HTML converter
// Handles the subset of AsciiDoc used in Mastering Bitcoin.
// Paragraphs: consecutive non-empty lines are joined into one <p>.

enum AsciidocParser {

    static func toHTML(_ adoc: String) -> String {
        let lines = adoc.components(separatedBy: "\n")
        var html = ""
        var i = 0
        var inCodeBlock = false
        var inAdmonition = false
        var admonitionType = ""
        var paragraphBuffer: [String] = []

        // Flush buffered paragraph lines into a single <p>
        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let text = paragraphBuffer.joined(separator: " ")
            html += "<p>\(inlineFormat(text))</p>\n"
            paragraphBuffer.removeAll()
        }

        while i < lines.count {
            let line = lines[i]

            // Code blocks (----)
            if line.hasPrefix("----") {
                flushParagraph()
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                i += 1
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                i += 1
                continue
            }

            // Admonition blocks: [TIP] / [NOTE] / [WARNING] followed by ====
            if line == "[TIP]" || line == "[NOTE]" || line == "[WARNING]" || line == "[IMPORTANT]" || line == "[CAUTION]" {
                flushParagraph()
                admonitionType = line.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                if i + 1 < lines.count && lines[i + 1].hasPrefix("====") {
                    i += 2
                    inAdmonition = true
                    html += "<blockquote class=\"admonition \(admonitionType.lowercased())\"><strong>\(admonitionType)</strong><br>"
                    continue
                }
            }

            // End of admonition block
            if inAdmonition && line.hasPrefix("====") {
                flushParagraph()
                html += "</blockquote>\n"
                inAdmonition = false
                i += 1
                continue
            }

            // Clean index annotations
            let cleaned = line
                .replacingOccurrences(of: "\\(\\(\\(\"[^\"]*\"\\)\\)\\)", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\(\\(\\([^)]*\\)\\)\\)", with: "", options: .regularExpression)

            // Skip anchor lines [[...]]
            if cleaned.hasPrefix("[[") && cleaned.hasSuffix("]]") {
                i += 1
                continue
            }

            // Skip source/role markers like [source,bash] or [.result]
            if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") && !cleaned.hasPrefix("[TIP") && !cleaned.hasPrefix("[NOTE") && !cleaned.hasPrefix("[WARN") && !cleaned.hasPrefix("[IMP") && !cleaned.hasPrefix("[CAUT") {
                i += 1
                continue
            }

            // Headers
            if cleaned.hasPrefix("===== ") {
                flushParagraph()
                html += "<h5>\(inlineFormat(String(cleaned.dropFirst(6))))</h5>\n"
            } else if cleaned.hasPrefix("==== ") {
                flushParagraph()
                html += "<h4>\(inlineFormat(String(cleaned.dropFirst(5))))</h4>\n"
            } else if cleaned.hasPrefix("=== ") {
                flushParagraph()
                html += "<h3>\(inlineFormat(String(cleaned.dropFirst(4))))</h3>\n"
            } else if cleaned.hasPrefix("== ") {
                flushParagraph()
                html += "<h2>\(inlineFormat(String(cleaned.dropFirst(3))))</h2>\n"
            } else if cleaned.hasPrefix("= ") && !cleaned.hasPrefix("==") {
                flushParagraph()
                html += "<h1>\(inlineFormat(String(cleaned.dropFirst(2))))</h1>\n"
            }
            // Images
            else if cleaned.hasPrefix("image::") {
                flushParagraph()
                let stripped = cleaned.replacingOccurrences(of: "image::", with: "")
                let parts = stripped.components(separatedBy: "[")
                let src = parts[0]
                let alt = parts.count > 1 ? parts[1].replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\"", with: "") : ""
                html += "<figure><img src=\"\(src)\" alt=\"\(alt)\"><figcaption>\(alt)</figcaption></figure>\n"
            }
            // Figure title (.Title text)
            else if cleaned.hasPrefix(".") && !cleaned.hasPrefix("..") && cleaned.count > 1 && cleaned[cleaned.index(after: cleaned.startIndex)].isLetter {
                flushParagraph()
                html += "<p class=\"figure-title\">\(inlineFormat(String(cleaned.dropFirst())))</p>\n"
            }
            // Unordered list
            else if cleaned.hasPrefix("* ") || cleaned.hasPrefix("- ") {
                flushParagraph()
                html += "<li>\(inlineFormat(String(cleaned.dropFirst(2))))</li>\n"
            }
            // Ordered list
            else if cleaned.hasPrefix(". ") && cleaned.count > 2 && cleaned[cleaned.index(cleaned.startIndex, offsetBy: 2)].isLetter {
                flushParagraph()
                html += "<li>\(inlineFormat(String(cleaned.dropFirst(2))))</li>\n"
            }
            // Empty line = paragraph break
            else if cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            }
            // Regular text line — accumulate into paragraph buffer
            else {
                paragraphBuffer.append(cleaned)
            }

            i += 1
        }

        flushParagraph()
        return html
    }

    // MARK: - Inline formatting

    private static func inlineFormat(_ text: String) -> String {
        var s = text

        // Remove any remaining index annotations
        s = s.replacingOccurrences(of: "\\(\\(\\(\"[^\"]*\"\\)\\)\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\(\\(\\([^)]*\\)\\)\\)", with: "", options: .regularExpression)

        // Inline code: `code` or +code+
        s = s.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\+([^+]+)\\+", with: "<code>$1</code>", options: .regularExpression)

        // Bold: *text*
        s = s.replacingOccurrences(of: "(?<![*])\\*([^*]+)\\*(?![*])", with: "<strong>$1</strong>", options: .regularExpression)

        // Italic: _text_
        s = s.replacingOccurrences(of: "(?<![_])_([^_]+)_(?![_])", with: "<em>$1</em>", options: .regularExpression)

        // Links: link:url[text]
        s = s.replacingOccurrences(of: "link:([^\\[]+)\\[([^\\]]+)\\]", with: "<a href=\"$1\">$2</a>", options: .regularExpression)

        // Cross-references: <<anchor, text>> or <<anchor>>
        s = s.replacingOccurrences(of: "<<([^,>]+),\\s*([^>]+)>>", with: "<em>$2</em>", options: .regularExpression)
        s = s.replacingOccurrences(of: "<<([^>]+)>>", with: "<em>$1</em>", options: .regularExpression)

        return s
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
