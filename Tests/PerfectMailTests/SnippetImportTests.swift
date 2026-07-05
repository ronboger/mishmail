import XCTest

final class SnippetImportTests: XCTestCase {

    func testDecode() throws {
        let json = """
        [{"name": "Zoom Link", "body": "Here's my zoom link: {zoom_link}"},
         {"name": "intro find time", "body": "Thanks {bcc_first_name}!", "movesToBcc": true}]
        """
        let items = try SnippetImport.decode(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "Zoom Link")
        XCTAssertNil(items[0].movesToBcc)
        XCTAssertEqual(items[1].movesToBcc, true)
    }

    func testPlanSkipsExistingNamesCaseInsensitively() {
        let items = [
            SnippetImport.Item(name: "Follow Up", body: "x", movesToBcc: nil),
            SnippetImport.Item(name: "New One", body: "y", movesToBcc: nil),
        ]
        let planned = SnippetImport.plan(items, existingNames: ["follow up"])
        XCTAssertEqual(planned.map(\.name), ["New One"])
    }

    func testPlanSkipsBlanksAndInFileDuplicates() {
        let items = [
            SnippetImport.Item(name: "  ", body: "x", movesToBcc: nil),
            SnippetImport.Item(name: "A", body: "  \n ", movesToBcc: nil),
            SnippetImport.Item(name: "B", body: "ok", movesToBcc: nil),
            SnippetImport.Item(name: "b", body: "dupe", movesToBcc: nil),
        ]
        XCTAssertEqual(SnippetImport.plan(items, existingNames: []).map(\.name), ["B"])
    }

    func testBadJSONThrows() {
        XCTAssertThrowsError(try SnippetImport.decode(Data("not json".utf8)))
    }

    func testDefaultsAreSeedableAndSelfConsistent() {
        let items = SnippetDefaults.items
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertFalse(item.name.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(items.filter { $0.movesToBcc == true }.map(\.name), ["intro find time"])
        XCTAssertEqual(SnippetImport.plan(items, existingNames: []).count, items.count)
        XCTAssertEqual(SnippetImport.plan(items, existingNames: items.map(\.name)).count, 0)
    }
}
