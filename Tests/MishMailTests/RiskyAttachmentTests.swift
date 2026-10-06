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

    /// Same classes as `html`, `fileloc`, `terminal`, `dmg` and `xlsm`,
    /// which already prompt: Launch Services opens all of these directly.
    func testFlagsWebLocationDiskImageAndMacroTypes() {
        let risky = [
            "xhtml", "xht", "shtml", "mht", "mhtml", "webarchive", "hta", "jnlp", "vbs",
            "url", "afploc", "ftploc", "nfsloc", "vncloc", "term",
            "sparseimage", "sparsebundle", "cdr", "xip",
            "xlam", "xla", "xltm", "dotm", "potm", "ppam", "ppsm", "sldm",
        ]
        for ext in risky {
            XCTAssertTrue(
                MessageParser.isRiskyAttachmentFilename("report.\(ext)"),
                "expected .\(ext) to prompt")
            XCTAssertTrue(
                MessageParser.isRiskyAttachmentFilename("REPORT.\(ext.uppercased())"),
                "expected .\(ext.uppercased()) to prompt")
        }
        // Plain Office and template formats without macros stay quiet.
        for ext in ["docx", "xlsx", "pptx", "dotx", "xltx", "potx", "csv", "png", "zip"] {
            XCTAssertFalse(
                MessageParser.isRiskyAttachmentFilename("report.\(ext)"),
                "did not expect .\(ext) to prompt")
        }
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
