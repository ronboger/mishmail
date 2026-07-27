import AppKit

/// Reopens MishMail once it has quit — after stripping quarantine from the
/// freshly installed bundle, which is the half a sandboxed MishMail cannot do.
///
/// Two facts shape this process, both verified the hard way across 0.4.2–0.4.5:
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

/// True while MishMail is still up. Asked through LaunchServices rather than
/// `kill(pid, 0)` purely for API niceness — either works now that this
/// process is unsandboxed.
func isAlive(_ pid: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: pid) != nil
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: MishMailRelauncher <pid> <app path>\n".utf8))
    exit(64)  // EX_USAGE
}
let target = URL(fileURLWithPath: args[2])

// Wait for MishMail to go. Launched before the swap, so the wait spans the
// install itself plus the database shutdown. Bounded, because if MishMail
// never quits — say the swap failed and it stayed up to show the fallback —
// reopening it would do nothing useful and this process should not linger.
let deadline = Date().addingTimeInterval(30)
while isAlive(pid), Date() < deadline {
    usleep(100_000)
}
guard !isAlive(pid) else { exit(1) }

// The whole reason this helper exists: make the new bundle launchable.
// Harmless when the install failed and the old, untagged bundle is still in
// place — stripping an absent attribute is a no-op.
Quarantine.strip(from: target)

// LaunchServices needs a beat to notice the process is gone; without it the
// open can be folded into the instance that is still shutting down.
usleep(300_000)

if NSWorkspace.shared.open(target) {
    exit(0)
}

// Last resort, and a real one now: this process is unsandboxed, so spawning
// `open` works. Never reached when the call above succeeds.
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
proc.arguments = [target.path]
do {
    try proc.run()
    proc.waitUntilExit()
    exit(proc.terminationStatus)
} catch {
    exit(70)  // EX_SOFTWARE
}
