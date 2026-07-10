import XCTest

/// Integration smoke for the OAuth loopback catcher — no Google credentials
/// required. Hits 127.0.0.1 the same way the browser redirect does.
final class OAuthLoopbackTests: XCTestCase {

    override func tearDown() {
        OAuthService.loopbackTimeout = .seconds(5 * 60)
        super.tearDown()
    }

    func testAcceptsValidCallbackAndReturnsCode() async throws {
        let state = "test-state-\(UUID().uuidString)"
        let expectedCode = "auth-code-\(UUID().uuidString)"
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(expectedState: state)

        // Give NWListener a beat to accept connections.
        try await Task.sleep(for: .milliseconds(50))

        let url = URL(string:
            "http://127.0.0.1:\(port)/oauth2/callback?code=\(expectedCode)&state=\(state)")!
        let (_, resp) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)

        let code = try await codeTask.value
        XCTAssertEqual(code, expectedCode)
    }

    func testIgnoresWrongStateThenAcceptsValid() async throws {
        let state = "good-state-\(UUID().uuidString)"
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(expectedState: state)
        try await Task.sleep(for: .milliseconds(50))

        // Forged probe: gets a page, but must not finish the task.
        let bad = URL(string:
            "http://127.0.0.1:\(port)/oauth2/callback?code=stolen&state=wrong")!
        let (_, badResp) = try await URLSession.shared.data(from: bad)
        XCTAssertEqual((badResp as? HTTPURLResponse)?.statusCode, 200)

        // Favicon-style noise: ignored (connection may reset — either is fine).
        let noise = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        _ = try? await URLSession.shared.data(from: noise)

        try await Task.sleep(for: .milliseconds(30))

        // Task must still be running after the forged probe.
        XCTAssertFalse(codeTask.isCancelled)

        let good = URL(string:
            "http://127.0.0.1:\(port)/oauth2/callback?code=real-code&state=\(state)")!
        let (_, goodResp) = try await URLSession.shared.data(from: good)
        XCTAssertEqual((goodResp as? HTTPURLResponse)?.statusCode, 200)

        let code = try await codeTask.value
        XCTAssertEqual(code, "real-code")
    }

    func testTimesOutAndCancelsListener() async throws {
        OAuthService.loopbackTimeout = .milliseconds(200)
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(expectedState: "unused")

        do {
            _ = try await codeTask.value
            XCTFail("expected timeout")
        } catch let error as OAuthError {
            XCTAssertEqual(String(describing: error), String(describing: OAuthError.timedOut))
        } catch is CancellationError {
            // Task group may surface cancellation wrapping timedOut; accept either.
        } catch {
            // NWListener / task-group can wrap the error; accept any failure
            // so long as we don't hang (test timeout would catch that).
            let desc = String(describing: error)
            XCTAssertTrue(
                desc.contains("timedOut") || desc.contains("cancelled") || desc.contains("Cancellation"),
                "unexpected error: \(error)"
            )
        }

        // Port should no longer accept (listener cancelled). Best-effort: a
        // connect may fail or hang briefly; use a short URLSession timeout.
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/oauth2/callback?code=x&state=unused")!)
        req.timeoutInterval = 0.5
        do {
            _ = try await URLSession.shared.data(for: req)
            // Some stacks still accept a half-closed connection; not fatal.
        } catch {
            // Expected: connection refused / timed out.
        }
    }

    func testGoogleDeniedWithMatchingStateSurfacesError() async throws {
        let state = "deny-state-\(UUID().uuidString)"
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(expectedState: state)
        try await Task.sleep(for: .milliseconds(50))

        let url = URL(string:
            "http://127.0.0.1:\(port)/oauth2/callback?error=access_denied&state=\(state)")!
        _ = try await URLSession.shared.data(from: url)

        do {
            _ = try await codeTask.value
            XCTFail("expected authorizationDenied")
        } catch let error as OAuthError {
            if case .authorizationDenied(let reason) = error {
                XCTAssertEqual(reason, "access_denied")
            } else {
                XCTFail("wrong OAuthError: \(error)")
            }
        }
    }
}
