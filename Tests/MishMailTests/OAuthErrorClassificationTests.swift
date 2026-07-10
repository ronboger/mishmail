import XCTest

final class OAuthErrorClassificationTests: XCTestCase {

    func testOAuthErrorCodeParsesInvalidGrant() {
        let json = #"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#
        XCTAssertEqual(OAuthService.oauthErrorCode(from: Data(json.utf8)), "invalid_grant")
    }

    func testOAuthErrorCodeParsesOtherErrors() {
        let json = #"{"error": "invalid_client", "error_description": "The OAuth client was not found."}"#
        XCTAssertEqual(OAuthService.oauthErrorCode(from: Data(json.utf8)), "invalid_client")
    }

    func testOAuthErrorCodeReturnsNilForNonJSON() {
        XCTAssertNil(OAuthService.oauthErrorCode(from: Data("not json".utf8)))
    }

    func testOAuthErrorCodeReturnsNilForMissingErrorField() {
        XCTAssertNil(OAuthService.oauthErrorCode(from: Data(#"{"foo": "bar"}"#.utf8)))
    }

    func testInvalidGrantErrorDescriptionMentionsReauthorize() {
        let message = OAuthError.invalidGrant.errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("reauthorize"))
    }

    func testNoRefreshTokenErrorDescriptionContainsEmailAndReauthorize() {
        let message = GmailError.noRefreshToken("x@y.com").errorDescription ?? ""
        XCTAssertTrue(message.contains("x@y.com"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("reauthorize"))
    }
}
