import XCTest
@testable import MishMail

final class TransientNetworkErrorTests: XCTestCase {

    func testDirectURLErrorsAreTransient() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .dataNotAllowed,
        ]
        for code in codes {
            XCTAssertTrue(
                MailStore.isTransientNetworkError(URLError(code)),
                "\(code) should be transient")
        }
    }

    func testNonTransientURLError() {
        XCTAssertFalse(MailStore.isTransientNetworkError(URLError(.badURL)))
        XCTAssertFalse(MailStore.isTransientNetworkError(URLError(.cancelled)))
        XCTAssertFalse(MailStore.isTransientNetworkError(URLError(.userAuthenticationRequired)))
    }

    func testWrappedNSUnderlyingURLErrorIsTransient() {
        let underlying = URLError(.notConnectedToInternet)
        let wrapped = NSError(
            domain: "MishMail.Test",
            code: 42,
            userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(
            MailStore.isTransientNetworkError(wrapped),
            "must unwrap NSUnderlyingErrorKey chains")
    }

    func testDeeplyWrappedURLErrorIsTransient() {
        let leaf = URLError(.networkConnectionLost)
        let mid = NSError(
            domain: "Mid",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: leaf])
        let outer = NSError(
            domain: "Outer",
            code: 2,
            userInfo: [NSUnderlyingErrorKey: mid])
        XCTAssertTrue(MailStore.isTransientNetworkError(outer))
    }

    func testNSURLErrorDomainNSErrorIsTransient() {
        let ns = NSError(
            domain: NSURLErrorDomain,
            code: URLError.timedOut.rawValue,
            userInfo: nil)
        XCTAssertTrue(MailStore.isTransientNetworkError(ns))
    }

    func testUnrelatedErrorIsNotTransient() {
        struct Boom: Error {}
        XCTAssertFalse(MailStore.isTransientNetworkError(Boom()))
        XCTAssertFalse(MailStore.isTransientNetworkError(
            NSError(domain: "MishMail", code: 1)))
    }
}
