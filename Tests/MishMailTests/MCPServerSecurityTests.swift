import XCTest

final class MCPServerSecurityTests: XCTestCase {
    func testConstantTimeTokenComparisonMatchesOnlyIdenticalBytes() {
        XCTAssertTrue(MCPServerSecurity.constantTimeEqual("secret", "secret"))
        XCTAssertTrue(MCPServerSecurity.constantTimeEqual("päss", "päss"))
        XCTAssertFalse(MCPServerSecurity.constantTimeEqual("secret", "secreT"))
        XCTAssertFalse(MCPServerSecurity.constantTimeEqual("secret", "secret-extra"))
        XCTAssertFalse(MCPServerSecurity.constantTimeEqual("secret", ""))
    }
}
