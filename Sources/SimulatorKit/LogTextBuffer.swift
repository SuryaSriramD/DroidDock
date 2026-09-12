import Foundation

/// The retained UI log document, bounded independently of streaming batches.
/// The byte limit includes newline separators in the rendered UTF-8 text.
/// This value is owned by the session's main actor; it does not own a reader.
public struct LogTextBuffer: Sendable {
    public static let maximumLines = 500
    public static let maximumUTF8Bytes = 1_048_576

    public private(set) var lines: [String] = []
    public private(set) var text = ""
    public private(set) var utf8ByteCount = 0
    public private(set) var revision: UInt64 = 0
    private var lineByteCounts: [Int] = []
    private var filtered: (revision: UInt64, query: String, text: String)?

    public init() {}

    /// Pause freezes the visible document while callers continue draining the
    /// stream. Entries received during that pause are intentionally not replayed.
    /// Returns false when the retained lines are unchanged, avoiding publication
    /// and document replacement for an identical full tail or an empty batch.
    @discardableResult
    public mutating func append(_ incoming: [String], paused: Bool = false) -> Bool {
        guard !paused, !incoming.isEmpty else { return false }
        let previous = lines
        // An input batch may itself exceed the line cap; only its latest entries
        // can survive, regardless of the prior document's contents.
        for source in incoming.suffix(Self.maximumLines) {
            let line = Self.boundedLine(source)
            let bytes = line.utf8.count
            utf8ByteCount += bytes + (lines.isEmpty ? 0 : 1)
            lines.append(line); lineByteCounts.append(bytes)
            while lines.count > Self.maximumLines || utf8ByteCount > Self.maximumUTF8Bytes {
                utf8ByteCount -= lineByteCounts.removeFirst() + (lines.count > 1 ? 1 : 0)
                lines.removeFirst()
            }
        }
        // Log bytes are preserved even when Swift considers two differently
        // normalized strings canonically equivalent (for example é and é).
        let unchanged = lines.count == previous.count && zip(lines, previous).allSatisfy {
            $0.utf8.elementsEqual($1.utf8)
        }
        guard !unchanged else { return false }
        text = lines.joined(separator: "\n")
        revision &+= 1
        filtered = nil
        return true
    }

    /// Cache one filtered document as well as the unfiltered text. SwiftUI may
    /// request this repeatedly for unrelated FPS/resource updates; only a changed
    /// query or changed retained lines requires another filter/join operation.
    public mutating func filteredText(matching query: String) -> String {
        guard !query.isEmpty else { return text }
        if let filtered, filtered.revision == revision, filtered.query == query { return filtered.text }
        let value = lines.filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")
        filtered = (revision, query, value)
        return value
    }

    private static func boundedLine(_ line: String) -> String {
        guard line.utf8.count > maximumUTF8Bytes else { return line }
        let marker = "[line truncated] "
        let budget = maximumUTF8Bytes - marker.utf8.count
        // A UTF-8 suffix may start within a scalar. Skip only those leading
        // continuation bytes so valid multibyte text never becomes replacement
        // characters and the marked result stays within the byte budget.
        let tail = line.utf8.suffix(budget).drop(while: { $0 & 0xC0 == 0x80 })
        return marker + String(decoding: tail, as: UTF8.self)
    }
}
