import XCTest

final class OAuthConfigTests: XCTestCase {

    func testParsesDesktopInstalledJSON() {
        let json = """
        {"installed":{"client_id":"123-abc.apps.googleusercontent.com",
        "project_id":"perfectmail","auth_uri":"https://accounts.google.com/o/oauth2/auth",
        "token_uri":"https://oauth2.googleapis.com/token","client_secret":"GOCSPX-secret",
        "redirect_uris":["http://localhost"]}}
        """
        let creds = OAuthConfig.parseCredentialsJSON(Data(json.utf8))
        XCTAssertEqual(creds?.clientID, "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(creds?.clientSecret, "GOCSPX-secret")
    }

    func testParsesWebKeyToo() {
        let json = #"{"web":{"client_id":"w.apps.googleusercontent.com","client_secret":"s"}}"#
        let creds = OAuthConfig.parseCredentialsJSON(Data(json.utf8))
        XCTAssertEqual(creds?.clientID, "w.apps.googleusercontent.com")
        XCTAssertEqual(creds?.clientSecret, "s")
    }

    func testRejectsGarbage() {
        XCTAssertNil(OAuthConfig.parseCredentialsJSON(Data("not json".utf8)))
        XCTAssertNil(OAuthConfig.parseCredentialsJSON(Data(#"{"foo":1}"#.utf8)))
        XCTAssertNil(OAuthConfig.parseCredentialsJSON(Data(#"{"installed":{"client_id":""}}"#.utf8)))
    }

    func testCallbackPathAcceptsRegisteredAndRoot() {
        XCTAssertTrue(OAuthService.isOAuthCallbackPath("/oauth2/callback"))
        XCTAssertTrue(OAuthService.isOAuthCallbackPath("/"))
        XCTAssertTrue(OAuthService.isOAuthCallbackPath(""))
    }

    func testCallbackPathRejectsUnrelatedProbes() {
        XCTAssertFalse(OAuthService.isOAuthCallbackPath("/favicon.ico"))
        XCTAssertFalse(OAuthService.isOAuthCallbackPath("/oauth2/callback/extra"))
        XCTAssertFalse(OAuthService.isOAuthCallbackPath("/admin"))
    }
}
