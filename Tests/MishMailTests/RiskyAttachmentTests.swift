import XCTest

final class RiskyAttachmentTests: XCTestCase {
    func testSafeOfficeAndImages() {
        XCTAssertFalse(MessageParser.isRiskyAttachmentFilename("report.pdf"))
        XCTAssertFalse(MessageParser.isRiskyAttachmentFilename("photo.JPG"))
        XCTAssertFalse(MessageParser.isRiskyAttachmentFilename("sheet.xlsx"))
        XCTAssertFalse(MessageParser.isRiskyAttachmentFilename("notes.txt"))
    }

    func testFlagsExecutablesAndInstallers() {
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("Setup.dmg"))
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("Payload.pkg"))
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("tool.command"))
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("run.sh"))
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("Evil.app"))
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("dropper.exe"))
    }

    func testDoubleExtension() {
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("invoice.pdf.app"))
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("readme.txt.sh"))
    }

    func testPathComponentsStrippedFirst() {
        // safeFilename reduces to bare name; risk check uses that.
        XCTAssertTrue(MessageParser.isRiskyAttachmentFilename("../../evil.app"))
        XCTAssertFalse(MessageParser.isRiskyAttachmentFilename("/tmp/docs/letter.pdf"))
    }
}
