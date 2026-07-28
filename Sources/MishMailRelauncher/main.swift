import AppKit

/// Reopens MishMail once it has quit — after stripping quarantine from the
/// freshly installed bundle, which is the half a sandboxed MishMail cannot do.
///
/// Two facts shape this process:
///
/// - Every file a sandboxed process writes is force-quarantined by the kernel,
///   and the sandbox denies `removexattr` on `com.apple.quarantine` (EPERM).
///   So the just-swapped-in update is always quarantined, and Gatekeeper
///   refuses to launch a quarantined un-notarized bundle (-10810) — including
///   the copy of this very helper inside it. That is why MishMail launches
///   *this* helper from its own still-registered, non-quarantined bundle
///   BEFORE the swap, and why this helper is signed without the sandbox
///   entitlement: unsandboxed, the removal actually works.
/// - MishMail cannot restart itself either way: a second instance of the
///   bundle it runs from is -10810, and post-swap the new bundle is
///   quarantined. A separate bundle id launched pre-swap sidesteps both.
///
/// Usage: `MishMailRelauncher <pid of MishMail> <path to MishMail.app>`
///
/// Every step appends a breadcrumb to `~/Library/Logs/MishMailRelauncher.log`:
/// this process runs headless in the half-second nobody is watching, its
/// failures leave no crash report, and macOS persists none of the usual
/// launch-time log lines for it.

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/MishMailRelauncher.log")

func crumb(_ message: String) {
    let stamp = ISO8601DateFormat.string(from: Date())
    let line = "\(stamp) [\(getpid())] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// `ISO8601DateFormatter` is thread-safe and cheap to keep around; wrapped so
/// `crumb` reads as one line.
enum ISO8601DateFormat {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func string(from date: Date) -> String { formatter.string(from: date) }
}

/// True while MishMail is still up. `kill(pid, 0)` against the ground truth
/// of the kernel's process table — 0 means alive, EPERM means alive but not
/// ours (impossible here, same user, but alive is alive). Deliberately not
/// `NSRunningApplication`: that adds a LaunchServices connection with its own
/// state, in a process young enough that nothing about its environment is
/// settled.
func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

let args = CommandLine.arguments
crumb("start: args=\(Array(args.dropFirst())) euid=\(geteuid()) " +
      "sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")

// Orders come from the plan file, not argv: a sandboxed MishMail cannot pass
// arguments (macOS strips them silently). Argv still wins when present so the
// helper can be exercised by hand: `MishMailRelauncher <pid> <app path>`.
let pid: pid_t
let target: URL
let markerURL: URL?
if args.count >= 3, let argvPid = pid_t(args[1]) {
    pid = argvPid
    target = URL(fileURLWithPath: args[2])
    markerURL = args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil
    crumb("plan from argv")
} else {
    let temp = Relaunch.containerTemp(home: FileManager.default.homeDirectoryForCurrentUser)
    let planURL = Relaunch.planURL(inTemp: temp)
    guard let data = try? Data(contentsOf: planURL),
          let plan = try? JSONDecoder().decode(Relaunch.Plan.self, from: data) else {
        crumb("exit 64: no argv and no readable plan at \(planURL.path)")
        FileHandle.standardError.write(
            Data("usage: MishMailRelauncher <pid> <app path>  (or a plan file)\n".utf8))
        exit(64)  // EX_USAGE
    }
    pid = plan.pid
    target = URL(fileURLWithPath: plan.appPath)
    markerURL = Relaunch.markerURL(inTemp: temp, nonce: plan.nonce)
    // Consumed: a crashed later attempt must not replay this run's orders.
    try? FileManager.default.removeItem(at: planURL)
    crumb("plan from \(planURL.path): pid=\(plan.pid) target=\(plan.appPath)")
}

// Handshake, before anything else: MishMail refuses to swap until this file
// exists, because a launch that is merely *requested* can still be destroyed
// by the swap replacing this very bundle.
if let markerURL {
    FileManager.default.createFile(atPath: markerURL.path, contents: Data())
    crumb("ready marker written: \(markerURL.path)")
}
crumb("watching pid \(pid), initially alive=\(isAlive(pid))")

// Wait for MishMail to go. Launched before the swap, so the wait spans the
// download's tail, the install itself, and the database shutdown. Bounded,
// because if MishMail never quits — say the swap failed and it stayed up to
// show the fallback — reopening it would do nothing useful and this process
// should not linger. 120 seconds rather than 30: a large mailbox's quit-path
// checkpoint is the slow part, and an expired deadline here strands the
// update quarantined and unlaunchable.
let start = Date()
let deadline = start.addingTimeInterval(120)
while isAlive(pid), Date() < deadline {
    usleep(100_000)
}
guard !isAlive(pid) else {
    crumb("exit 1: pid \(pid) still alive at deadline")
    exit(1)
}
crumb("pid \(pid) gone after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

// The whole reason this helper exists: make the new bundle launchable.
// Harmless when the install failed and the old, untagged bundle is still in
// place — stripping an absent attribute is a no-op.
let stripped = Quarantine.strip(from: target)
crumb("stripped quarantine from \(stripped) items under \(target.path)")

// LaunchServices needs a beat to notice the process is gone; without it the
// open can be folded into the instance that is still shutting down.
usleep(300_000)

if NSWorkspace.shared.open(target) {
    crumb("exit 0: NSWorkspace.open succeeded")
    exit(0)
}
crumb("NSWorkspace.open failed, falling back to /usr/bin/open")

// Last resort, and a real one now: this process is unsandboxed, so spawning
// `open` works. Never reached when the call above succeeds.
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
proc.arguments = [target.path]
do {
    try proc.run()
    proc.waitUntilExit()
    crumb("exit \(proc.terminationStatus): /usr/bin/open fallback")
    exit(proc.terminationStatus)
} catch {
    crumb("exit 70: could not spawn /usr/bin/open: \(error.localizedDescription)")
    exit(70)  // EX_SOFTWARE
}
