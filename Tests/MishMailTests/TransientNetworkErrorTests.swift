import XCTest

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
                TransientNetworkError.isTransient(URLError(code)),
                "\(code) should be transient")
        }
    }

    func testNonTransientURLError() {
        XCTAssertFalse(TransientNetworkError.isTransient(URLError(.badURL)))
        XCTAssertFalse(TransientNetworkError.isTransient(URLError(.cancelled)))
        XCTAssertFalse(TransientNetworkError.isTransient(URLError(.userAuthenticationRequired)))
    }

    func testWrappedNSUnderlyingURLErrorIsTransient() {
        let underlying = URLError(.notConnectedToInternet)
        let wrapped = NSError(
            domain: "MishMail.Test",
            code: 42,
            userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(
            TransientNetworkError.isTransient(wrapped),
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
        XCTAssertTrue(TransientNetworkError.isTransient(outer))
    }

    func testNSURLErrorDomainNSErrorIsTransient() {
        let ns = NSError(
            domain: NSURLErrorDomain,
            code: URLError.timedOut.rawValue,
            userInfo: nil)
        XCTAssertTrue(TransientNetworkError.isTransient(ns))
    }

    func testUnrelatedErrorIsNotTransient() {
        struct Boom: Error {}
        XCTAssertFalse(TransientNetworkError.isTransient(Boom()))
        XCTAssertFalse(TransientNetworkError.isTransient(
            NSError(domain: "MishMail", code: 1)))
    }
}
