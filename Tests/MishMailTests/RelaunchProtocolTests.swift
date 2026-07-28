import XCTest

/// The app↔relauncher plan-file contract. The two processes compute the same
/// paths from different starting points — the app from its sandboxed
/// temporary directory, the helper from the real home directory — and argv
/// is not available to reconcile them (macOS strips it for sandboxed
/// launchers), so these derivations agreeing IS the protocol.
final class RelaunchProtocolTests: XCTestCase {

    func testHelperDerivesTheSandboxedAppsTempDirectory() {
        let home = URL(fileURLWithPath: "/Users/ron")
        XCTAssertEqual(
            Relaunch.containerTemp(home: home).path,
            "/Users/ron/Library/Containers/dev.ronboger.MishMail/Data/tmp")
    }

    func testPlanAndMarkerLiveInTheSameDirectoryOnBothSides() {
        let appSide = URL(fileURLWithPath: "/Users/ron/Library/Containers/dev.ronboger.MishMail/Data/tmp")
        let helperSide = Relaunch.containerTemp(home: URL(fileURLWithPath: "/Users/ron"))
        XCTAssertEqual(Relaunch.planURL(inTemp: appSide).path,
                       Relaunch.planURL(inTemp: helperSide).path)
        XCTAssertEqual(Relaunch.markerURL(inTemp: appSide, nonce: "n1").path,
                       Relaunch.markerURL(inTemp: helperSide, nonce: "n1").path)
    }

    func testMarkerNameCarriesTheNonce() {
        let temp = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(Relaunch.markerURL(inTemp: temp, nonce: "abc").lastPathComponent,
                       "relauncher-ready-abc")
        XCTAssertNotEqual(Relaunch.markerURL(inTemp: temp, nonce: "abc").path,
                          Relaunch.markerURL(inTemp: temp, nonce: "def").path)
    }

    func testPlanRoundTripsThroughJSON() throws {
        let plan = Relaunch.Plan(pid: 4242, appPath: "/Applications/MishMail.app", nonce: "n")
        let decoded = try JSONDecoder().decode(Relaunch.Plan.self,
                                               from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.pid, 4242)
        XCTAssertEqual(decoded.appPath, "/Applications/MishMail.app")
        XCTAssertEqual(decoded.nonce, "n")
    }
}
