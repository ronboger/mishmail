import Foundation
import os

/// Persistent, greppable record of failures that a banner would otherwise
/// swallow. Gmail HTTP errors are written in full (status, endpoint, Google's
/// JSON body) to `~/Library/Logs/MishMail/diagnostics.log` inside the app
/// container, and to the unified log under `dev.ronboger.MishMail.diag`.
///
/// Never logs tokens: requests are recorded by method and path only (query
/// dropped), and Google's error bodies carry no credentials.
enum DiagnosticLog {
    static let subsystem = "dev.ronboger.MishMail.diag"
    /// Rotate to `diagnostics.log.1` past this size so the file stays small.
    static let maxBytes = 512 * 1024
    static let maxBodyChars = 4000

    private static let logger = Logger(subsystem: subsystem, category: "errors")
    private static let queue = DispatchQueue(label: "dev.ronboger.MishMail.diagnostics")

    static var fileURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/MishMail/diagnostics.log")
    }

    /// One Gmail (or Google userinfo) HTTP failure.
    static func gmailHTTP(account: String, method: String, path: String,
                          code: Int, body: String, note: String? = nil) {
        record(format(account: account, method: method, path: path,
                      code: code, body: body, note: note))
    }

    /// A sync pass that ended in an error the user may see as a banner.
    static func syncFailure(account: String, error: Error) {
        record("SYNC-FAIL account=\(account) \(describe(error))")
    }

    /// Full description: `GmailError.http` keeps its whole body (the banner
    /// text truncates it), everything else uses the localized description.
    static func describe(_ error: Error) -> String {
        if case GmailError.http(let code, let body) = error {
            return "http=\(code) body=\(clip(body))"
        }
        return "error=\(String(describing: type(of: error))) \(error.localizedDescription)"
    }

    static func format(account: String, method: String, path: String,
                       code: Int, body: String, note: String? = nil) -> String {
        var line = "GMAIL-HTTP account=\(account) \(method) \(path) status=\(code)"
        if let note { line += " note=\(note)" }
        line += " body=\(clip(body))"
        return line
    }

    static func clip(_ body: String) -> String {
        let flat = body.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return flat.count > maxBodyChars ? String(flat.prefix(maxBodyChars)) + "…" : flat
    }

    static func record(_ message: String) {
        logger.error("\(message, privacy: .public)")
        queue.async { append(message, to: fileURL, now: Date()) }
    }

    static func append(_ message: String, to url: URL, now: Date) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let line = "\(ISO8601DateFormatter().string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            logger.error("diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
