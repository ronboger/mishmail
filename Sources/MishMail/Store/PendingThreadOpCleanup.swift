import Foundation
import GRDB

extension PendingThreadOp {
    /// Delete a queued edit whose account row no longer exists; returns true
    /// when it was deleted. The check runs against the database inside the
    /// caller's write, so a stale in-memory account list cannot drop a row
    /// that still has an owner. `pendingThreadOp` has no foreign key to
    /// `account`, so these rows do not cascade away with the account.
    @discardableResult
    static func deleteIfAccountMissing(_ db: Database, row: PendingThreadOp) throws -> Bool {
        guard try Account.fetchOne(db, key: row.accountId) == nil else { return false }
        return try PendingThreadOp.deleteOne(db, key: row.id)
    }
}
