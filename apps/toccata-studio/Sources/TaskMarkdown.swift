import Foundation

struct TaskMarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedItem(String)
        case orderedItem(number: Int, text: String)
        case quote(String)
        case code(language: String?, text: String)
        case divider
    }

    let id: Int
    let kind: Kind
}

enum TaskMarkdownParser {
    static func blocks(from markdown: String) -> [TaskMarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [TaskMarkdownBlock] = []
        var index = 0

        func append(_ kind: TaskMarkdownBlock.Kind) {
            blocks.append(TaskMarkdownBlock(id: blocks.count, kind: kind))
        }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                index += 1
                continue
            }
            if let (marker, language) = fence(in: line) {
                var code: [String] = []
                index += 1
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces) != marker {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                append(.code(language: language, text: code.joined(separator: "\n")))
                continue
            }
            if let heading = heading(in: line) {
                append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            if isDivider(line) {
                append(.divider)
                index += 1
                continue
            }
            if let item = unorderedItem(in: line) {
                append(.unorderedItem(item))
                index += 1
                continue
            }
            if let item = orderedItem(in: line) {
                append(.orderedItem(number: item.number, text: item.text))
                index += 1
                continue
            }
            if line.hasPrefix(">") {
                append(.quote(quote(in: line)))
                index += 1
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || isBlockStart(candidate) { break }
                paragraph.append(candidate)
                index += 1
            }
            append(.paragraph(paragraph.joined(separator: " ")))
        }
        return blocks
    }

    private static func isBlockStart(_ line: String) -> Bool {
        fence(in: line) != nil || heading(in: line) != nil || isDivider(line)
            || unorderedItem(in: line) != nil || orderedItem(in: line) != nil || line.hasPrefix(">")
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func unorderedItem(in line: String) -> String? {
        guard let marker = line.first, ["-", "+", "*"].contains(marker),
              line.dropFirst().first == " " else { return nil }
        let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func orderedItem(in line: String) -> (number: Int, text: String)? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let marker = parts.first,
              marker.hasSuffix(".") || marker.hasSuffix(")"),
              let number = Int(marker.dropLast()) else { return nil }
        return (number, String(parts[1]))
    }

    private static func quote(in line: String) -> String {
        String(line.dropFirst().drop(while: { $0 == " " }))
    }

    private static func fence(in line: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let language = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return (marker, language.isEmpty ? nil : language)
        }
        return nil
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3, let marker = line.first, ["-", "*", "_"].contains(marker) else { return false }
        return line.allSatisfy { $0 == marker }
    }
}

enum TaskMarkdownInline {
    static func attributedString(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
