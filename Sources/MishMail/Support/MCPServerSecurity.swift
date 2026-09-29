import Foundation

/// Small security primitives shared by the MCP listener and its tests.
enum MCPServerSecurity {
    /// Compares bearer tokens without returning early on the first mismatch.
    /// The token length is necessarily observable, but byte contents are not
    /// used to choose an early exit.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}
