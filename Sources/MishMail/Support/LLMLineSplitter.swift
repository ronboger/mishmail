import Foundation

/// Splits a streamed response body into lines for the SSE / NDJSON codecs.
///
/// `URLSession.AsyncBytes.lines` also breaks at U+2028, U+2029 and U+0085.
/// JSON allows those raw inside a string, and mail text holds them, so one
/// event arrived as two halves that both failed to parse: a lost text
/// fragment, or tool arguments that were no longer valid JSON. Only LF and
/// CR end a line here. Neither can appear raw inside a JSON string, so a
/// terminator never cuts an event.
struct LLMLineSplitter {
    private var buffer: [UInt8] = []

    /// Feeds one byte. Returns a complete line when `byte` ends a non-empty
    /// one. Blank lines (SSE event separators, the LF of a CRLF) give nil.
    mutating func append(_ byte: UInt8) -> String? {
        guard byte == 0x0A || byte == 0x0D else {
            buffer.append(byte)
            return nil
        }
        return takeLine()
    }

    /// Feeds a chunk and returns every line it completes.
    mutating func append<S: Sequence>(contentsOf bytes: S) -> [String] where S.Element == UInt8 {
        bytes.compactMap { append($0) }
    }

    /// The unterminated tail, once the body has ended.
    mutating func finish() -> String? {
        takeLine()
    }

    private mutating func takeLine() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}
