import XCTest

final class FromPickerModelTests: XCTestCase {
    private func identity(_ email: String, name: String = "", account: String? = nil)
        -> SendIdentity {
        SendIdentity(email: email, displayName: name, accountId: account ?? email,
                     isPrimary: account == nil, isDefault: false)
    }

    func testStepWrapsBothWays() {
        XCTAssertEqual(FromPickerModel.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(FromPickerModel.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(FromPickerModel.step(from: 1, by: 1, count: 3), 2)
    }

    func testStepFromNoSelectionStartsAtEdge() {
        XCTAssertEqual(FromPickerModel.step(from: nil, by: 1, count: 3), 0)
        XCTAssertEqual(FromPickerModel.step(from: nil, by: -1, count: 3), 2)
    }

    func testStepHandlesEmptyAndSingle() {
        XCTAssertNil(FromPickerModel.step(from: 0, by: 1, count: 0))
        XCTAssertEqual(FromPickerModel.step(from: 0, by: 1, count: 1), 0)
        XCTAssertEqual(FromPickerModel.step(from: 0, by: -1, count: 1), 0)
    }

    func testTypeAheadMatchesEmailOrNameAfterCurrent() {
        let rows = [identity("ron@berkeley.edu", name: "Ron Boger"),
                    identity("hello@lab.org", name: "Lab"),
                    identity("ronboger@gmail.com")]
        XCTAssertEqual(FromPickerModel.match(prefix: "r", in: rows, after: nil), 0)
        XCTAssertEqual(FromPickerModel.match(prefix: "r", in: rows, after: 0), 2)
        XCTAssertEqual(FromPickerModel.match(prefix: "R", in: rows, after: 2), 0)
        XCTAssertEqual(FromPickerModel.match(prefix: "lab", in: rows, after: nil), 1)
        XCTAssertNil(FromPickerModel.match(prefix: "z", in: rows, after: nil))
        XCTAssertNil(FromPickerModel.match(prefix: " ", in: rows, after: nil))
    }

    func testDetailShowsNameAndVia() {
        XCTAssertEqual(FromPickerModel.detail(for: identity("a@x.com")), "")
        XCTAssertEqual(FromPickerModel.detail(for: identity("a@x.com", name: "Ann")), "Ann")
        XCTAssertEqual(
            FromPickerModel.detail(for: identity("a@x.com", name: "Ann", account: "me@gmail.com")),
            "Ann · via me@gmail.com")
        XCTAssertEqual(
            FromPickerModel.detail(for: identity("a@x.com", name: "a@x.com", account: "me@gmail.com")),
            "via me@gmail.com")
    }
}
