import XCTest
@testable import SimulatorKit

final class LogTextBufferTests: XCTestCase {
    private func assertBounds(_ buffer: LogTextBuffer, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(buffer.lines.count, LogTextBuffer.maximumLines, file: file, line: line)
        XCTAssertLessThanOrEqual(buffer.utf8ByteCount, LogTextBuffer.maximumUTF8Bytes, file: file, line: line)
        XCTAssertEqual(buffer.text, buffer.lines.joined(separator: "\n"), file: file, line: line)
        XCTAssertEqual(buffer.utf8ByteCount, buffer.text.utf8.count, file: file, line: line)
    }

    func testSuccessiveBatchesRetainLatestFiveHundredEntries() {
        var buffer = LogTextBuffer()
        let incoming = (0..<600).map { "line \($0)" }
        XCTAssertTrue(buffer.append(Array(incoming.prefix(300))))
        XCTAssertTrue(buffer.append(Array(incoming.suffix(300))))
        XCTAssertEqual(buffer.lines, Array(incoming.suffix(LogTextBuffer.maximumLines)))
        XCTAssertTrue(buffer.append(["newest"]))
        XCTAssertEqual(buffer.lines, Array(incoming.suffix(LogTextBuffer.maximumLines - 1)) + ["newest"])
        assertBounds(buffer)
    }

    func testByteOverflowAcrossBatchesDiscardsOldestCompleteEntries() {
        var buffer = LogTextBuffer()
        let size = 300_000
        let entries = ["a", "b", "c", "d", "e"].map { String(repeating: $0, count: size) }
        XCTAssertTrue(buffer.append(Array(entries.prefix(2))))
        XCTAssertEqual(buffer.utf8ByteCount, size * 2 + 1)
        XCTAssertTrue(buffer.append(Array(entries[2...3])))
        XCTAssertEqual(buffer.lines, Array(entries[1...3]))
        XCTAssertEqual(buffer.utf8ByteCount, size * 3 + 2)
        XCTAssertTrue(buffer.append([entries[4]]))
        XCTAssertEqual(buffer.lines, Array(entries[2...4]))
        assertBounds(buffer)
    }

    func testOversizedUnicodeLineKeepsValidSuffixAndCountsTruncationMarker() {
        var buffer = LogTextBuffer()
        let original = String(repeating: "🙂", count: LogTextBuffer.maximumUTF8Bytes / 4 + 100)
        let marker = "[line truncated] "
        XCTAssertTrue(buffer.append([original]))
        XCTAssertEqual(buffer.lines.count, 1)
        let retained = buffer.lines[0]
        XCTAssertTrue(retained.hasPrefix(marker))
        XCTAssertFalse(retained.contains("\u{FFFD}"), "A byte boundary must not create replacement characters")
        let suffix = String(retained.dropFirst(marker.count))
        XCTAssertFalse(suffix.isEmpty)
        XCTAssertTrue(original.hasSuffix(suffix))
        XCTAssertTrue(suffix.allSatisfy { $0 == "🙂" })
        XCTAssertEqual(buffer.utf8ByteCount, marker.utf8.count + suffix.utf8.count)
        assertBounds(buffer)
    }

    func testNewlineSeparatorsAndEmptyEntriesParticipateInLimits() {
        var buffer = LogTextBuffer()
        let first = String(repeating: "a", count: LogTextBuffer.maximumUTF8Bytes / 2)
        let second = String(repeating: "b", count: LogTextBuffer.maximumUTF8Bytes - first.utf8.count - 1)
        XCTAssertTrue(buffer.append([first, second]))
        XCTAssertEqual(buffer.utf8ByteCount, LogTextBuffer.maximumUTF8Bytes)
        XCTAssertEqual(buffer.lines, [first, second])
        XCTAssertTrue(buffer.append([""]))
        XCTAssertEqual(buffer.lines, [second, ""], "The extra separator must evict the oldest complete entry")
        XCTAssertEqual(buffer.utf8ByteCount, second.utf8.count + 1)
        assertBounds(buffer)

        var blanks = LogTextBuffer()
        XCTAssertTrue(blanks.append(Array(repeating: "", count: LogTextBuffer.maximumLines + 10)))
        XCTAssertEqual(blanks.lines.count, LogTextBuffer.maximumLines)
        XCTAssertEqual(blanks.utf8ByteCount, LogTextBuffer.maximumLines - 1)
        assertBounds(blanks)
    }

    func testPauseFreezesSnapshotAndResumeDoesNotReplayDroppedBatches() {
        var buffer = LogTextBuffer()
        XCTAssertTrue(buffer.append(["before pause", "keep this"]))
        let revision = buffer.revision
        let text = buffer.text
        let bytes = buffer.utf8ByteCount
        XCTAssertFalse(buffer.append(["discard while paused"], paused: true))
        XCTAssertFalse(buffer.append([String(repeating: "x", count: LogTextBuffer.maximumUTF8Bytes + 1)], paused: true))
        XCTAssertEqual(buffer.revision, revision)
        XCTAssertEqual(buffer.text, text)
        XCTAssertEqual(buffer.utf8ByteCount, bytes)
        XCTAssertEqual(buffer.filteredText(matching: "keep"), "keep this")
        XCTAssertTrue(buffer.append(["after resume"]))
        XCTAssertEqual(buffer.lines, ["before pause", "keep this", "after resume"])
        XCTAssertEqual(buffer.revision, revision + 1)
        assertBounds(buffer)
    }

    func testFilterChangesWithQueryAndContentWithoutMutatingVisibleHistory() {
        var buffer = LogTextBuffer()
        XCTAssertTrue(buffer.append(["Alpha event", "beta event", "ALPHABET result"]))
        let revision = buffer.revision
        XCTAssertEqual(buffer.filteredText(matching: "alpha"), "Alpha event\nALPHABET result")
        XCTAssertEqual(buffer.filteredText(matching: "BETA"), "beta event")
        XCTAssertEqual(buffer.filteredText(matching: "missing"), "")
        XCTAssertEqual(buffer.filteredText(matching: ""), buffer.text)
        XCTAssertEqual(buffer.revision, revision, "Filtering is a view of the same captured history")
        XCTAssertTrue(buffer.append(["Beta updated"]))
        XCTAssertEqual(buffer.filteredText(matching: "BETA"), "beta event\nBeta updated")
        XCTAssertEqual(buffer.filteredText(matching: "alpha"), "Alpha event\nALPHABET result")
        assertBounds(buffer)
    }

    func testEmptyAndIdenticalVisibleTailDoNotAdvanceRevision() {
        var buffer = LogTextBuffer()
        XCTAssertEqual(buffer.revision, 0)
        XCTAssertFalse(buffer.append([]))
        XCTAssertEqual(buffer.revision, 0)
        XCTAssertTrue(buffer.append(Array(repeating: "same", count: LogTextBuffer.maximumLines)))
        let revision = buffer.revision
        let text = buffer.text
        XCTAssertFalse(buffer.append(["same"]))
        XCTAssertFalse(buffer.append([]))
        XCTAssertEqual(buffer.revision, revision)
        XCTAssertEqual(buffer.text, text)
        XCTAssertTrue(buffer.append(["different"]))
        XCTAssertEqual(buffer.revision, revision + 1)
        XCTAssertEqual(buffer.lines.last, "different")
        assertBounds(buffer)

        // Canonically equivalent strings can still have different UTF-8 bytes.
        // Their replacement must refresh both cached text and its byte count.
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        XCTAssertTrue(buffer.append(Array(repeating: composed, count: LogTextBuffer.maximumLines)))
        let composedRevision = buffer.revision
        XCTAssertTrue(buffer.append(Array(repeating: decomposed, count: LogTextBuffer.maximumLines)))
        let expected = Array(repeating: decomposed, count: LogTextBuffer.maximumLines).joined(separator: "\n")
        XCTAssertEqual(buffer.revision, composedRevision + 1)
        XCTAssertEqual(Array(buffer.text.utf8), Array(expected.utf8))
        XCTAssertEqual(buffer.utf8ByteCount, expected.utf8.count)
        assertBounds(buffer)
    }
}
