import Foundation

/// A generated replacement stays separate from the live draft until applied.
/// UTF-16 offsets come from NSTextView; reject invalid or stale selections.
struct ComposeAIProposal: Equatable {
    let originalBody: String
    let range: NSRange
    var text = ""

    init?(body: String, range: NSRange) {
        let source = body as NSString
        let length = source.length
        guard range.location >= 0, range.location <= length,
              range.length >= 0, range.length <= length - range.location,
              Range(range, in: body) != nil else { return nil }
        func splitsSurrogate(at offset: Int) -> Bool {
            guard offset > 0, offset < length else { return false }
            return (0xD800...0xDBFF).contains(source.character(at: offset - 1))
                && (0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        guard !splitsSurrogate(at: range.location),
              !splitsSurrogate(at: range.location + range.length) else { return nil }
        originalBody = body
        self.range = range
    }

    var selectedText: String { (originalBody as NSString).substring(with: range) }
    var caretUTF16: Int { range.location + (text as NSString).length }

    func applying(to body: String) -> String? {
        guard body == originalBody,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (body as NSString).replacingCharacters(in: range, with: text)
    }
}
