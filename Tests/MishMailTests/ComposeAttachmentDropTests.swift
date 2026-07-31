import XCTest
import AppKit

final class ComposeAttachmentDropTests: XCTestCase {
    func testDedupeAppendSkipsPathDuplicates() {
        let a = URL(fileURLWithPath: "/tmp/a.pdf")
        let b = URL(fileURLWithPath: "/tmp/b.pdf")
        let aAgain = URL(fileURLWithPath: "/tmp/a.pdf")
        let result = ComposeAttachmentDrop.dedupeAppend(existing: [a],
                                                        incoming: [b, aAgain, b])
        XCTAssertEqual(result.map(\.path), ["/tmp/a.pdf", "/tmp/b.pdf"])
    }

    func testDedupeAppendIgnoresNonFileURLs() {
        let file = URL(fileURLWithPath: "/tmp/doc.pdf")
        let web = URL(string: "https://example.com/doc.pdf")!
        let result = ComposeAttachmentDrop.dedupeAppend(existing: [],
                                                        incoming: [web, file])
        XCTAssertEqual(result.map(\.lastPathComponent), ["doc.pdf"])
    }

    func testDedupeAppendPreservesExistingOrder() {
        let a = URL(fileURLWithPath: "/tmp/a.pdf")
        let b = URL(fileURLWithPath: "/tmp/b.pdf")
        let c = URL(fileURLWithPath: "/tmp/c.pdf")
        let result = ComposeAttachmentDrop.dedupeAppend(existing: [a, b],
                                                        incoming: [c, a])
        XCTAssertEqual(result.map(\.lastPathComponent), ["a.pdf", "b.pdf", "c.pdf"])
    }

    func testDedupeAppendStandardizesPaths() {
        // `/tmp/./x.pdf` and `/tmp/x.pdf` are the same file.
        let a = URL(fileURLWithPath: "/tmp/./x.pdf")
        let b = URL(fileURLWithPath: "/tmp/x.pdf")
        let result = ComposeAttachmentDrop.dedupeAppend(existing: [a],
                                                        incoming: [b])
        XCTAssertEqual(result.count, 1)
    }

    func testFileURLsFromEmptyPasteboard() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        XCTAssertTrue(ComposeAttachmentDrop.fileURLs(from: pb).isEmpty)
        XCTAssertFalse(ComposeAttachmentDrop.containsFileURLs(pb))
    }

    func testFileURLsFromPasteboardReadsFileOnly() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let file = URL(fileURLWithPath: "/tmp/attach-test.pdf")
        let web = URL(string: "https://example.com/x.pdf")!
        pb.writeObjects([file as NSURL, web as NSURL])
        let urls = ComposeAttachmentDrop.fileURLs(from: pb)
        XCTAssertEqual(urls.map(\.path), [file.path])
        XCTAssertTrue(ComposeAttachmentDrop.containsFileURLs(pb))
    }
}
