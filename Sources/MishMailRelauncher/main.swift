import AppKit

/// Reopens MishMail once it has quit, and nothing else.
///
/// MishMail cannot restart itself. Asking LaunchServices for a second instance
/// of the bundle you are running from fails with -10810, and the sandbox
/// blocks spawning a shell to do it after the fact — both were tried and both
/// failed in the wild. This runs as a separate bundle id, launched *before*
/// MishMail terminates, so by the time it acts there is no running instance to
/// conflict with and no stale registration to resolve.
///
/// Usage: `MishMailRelauncher <pid of MishMail> <path to MishMail.app>`

/// True while MishMail is still up.
///
/// Asked through LaunchServices rather than `kill(pid, 0)`: this helper is
/// built with the app's entitlements, so it is sandboxed, and a sandboxed
/// process may not signal another one — `kill` fails with EPERM and every
/// check reads as "already gone". That made an earlier version reopen MishMail
/// while it was still running, which does nothing at all, and then exit before
/// the quit it was supposed to be waiting for.
func isAlive(_ pid: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: pid) != nil
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: MishMailRelauncher <pid> <app path>\n".utf8))
    exit(64)  // EX_USAGE
}
let target = URL(fileURLWithPath: args[2])

// Wait for MishMail to go. Bounded, because if it never quits then reopening
// it would do nothing useful and this process should not linger forever.
let deadline = Date().addingTimeInterval(30)
while isAlive(pid), Date() < deadline {
    usleep(100_000)
}
guard !isAlive(pid) else { exit(1) }

// LaunchServices needs a beat to notice the process is gone; without it the
// open can be folded into the instance that is still shutting down.
usleep(300_000)

if NSWorkspace.shared.open(target) {
    exit(0)
}

// Last resort. This inherits MishMail's sandbox, which blocks spawning, so it
// only helps in a build where the helper is signed without those entitlements
// — cheap to keep, and never reached when the call above succeeds.
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
