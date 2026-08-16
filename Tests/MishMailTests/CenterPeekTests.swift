import XCTest

final class CenterPeekTests: XCTestCase {
    func testWideHostCapsTheCardAtAReadableColumn() {
        let size = CenterPeekLayout.cardSize(host: .init(width: 2_000, height: 1_200))
        XCTAssertEqual(size.width, CenterPeekLayout.maximumCardWidth)
        XCTAssertEqual(size.height, 1_200 - CenterPeekLayout.verticalInset * 2)
    }

    func testTypicalHostUsesTheWidthFraction() {
        let size = CenterPeekLayout.cardSize(host: .init(width: 1_200, height: 900))
        XCTAssertEqual(size.width, 1_200 * CenterPeekLayout.widthFraction)
    }

    func testNarrowHostKeepsTheBackdropMarginInsteadOfOverflowing() {
        // 560pt host: the 520pt floor would leave <48pt margins, so the
        // card yields to the inset instead.
        let size = CenterPeekLayout.cardSize(host: .init(width: 560, height: 700))
        XCTAssertEqual(size.width, 560 - CenterPeekLayout.horizontalInset * 2)
    }

    func testDegenerateHostNeverGoesNegative() {
        let size = CenterPeekLayout.cardSize(host: .init(width: 40, height: 20))
        XCTAssertGreaterThanOrEqual(size.width, 0)
        XCTAssertGreaterThanOrEqual(size.height, 0)
    }
}
