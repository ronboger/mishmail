import XCTest

/// Cache validity for the reading pane used to hang off a single global
/// counter that `reloadThreads()` bumped unconditionally — so one trash or
/// mark-read evicted all ten cached payloads, including the neighbors the
/// prefetch had just warmed. These pin the per-thread scoping that replaced it.
final class ThreadContentRevisionsTests: XCTestCase {
    func testUnrelatedThreadKeepsItsRevisionWhenAnotherThreadChanges() {
        var revisions = ThreadContentRevisions()
        let before = revisions.revision(of: "b")

        revisions.apply(.threads(["a"]))

        XCTAssertEqual(revisions.revision(of: "b"), before)
    }

    func testChangedThreadGetsANewRevision() {
        var revisions = ThreadContentRevisions()
        let before = revisions.revision(of: "a")

        revisions.apply(.threads(["a"]))

        XCTAssertNotEqual(revisions.revision(of: "a"), before)
    }

    func testEverythingChangesEveryThreadsRevision() {
        var revisions = ThreadContentRevisions()
        let beforeA = revisions.revision(of: "a")
        let beforeB = revisions.revision(of: "b")

        revisions.apply(.everything)

        XCTAssertNotEqual(revisions.revision(of: "a"), beforeA)
        XCTAssertNotEqual(revisions.revision(of: "b"), beforeB)
    }

    func testNoChangeReportsNothingToPublish() {
        var revisions = ThreadContentRevisions()

        XCTAssertFalse(revisions.apply(.none))
        XCTAssertFalse(revisions.apply(.threads([])))
        XCTAssertTrue(revisions.apply(.threads(["a"])))
        XCTAssertTrue(revisions.apply(.everything))
    }

    /// An epoch bump clears the per-thread counters to bound the map, so the
    /// epoch must carry enough identity on its own that a reset counter can
    /// never collide with a revision some cache entry is still holding.
    func testEpochBumpNeverReproducesAPriorRevision() {
        var revisions = ThreadContentRevisions()
        revisions.apply(.threads(["a"]))
        revisions.apply(.threads(["a"]))
        revisions.apply(.threads(["a"]))
        let beforeEpoch = revisions.revision(of: "a")

        revisions.apply(.everything)
        XCTAssertNotEqual(revisions.revision(of: "a"), beforeEpoch)

        revisions.apply(.threads(["a"]))
        revisions.apply(.threads(["a"]))
        revisions.apply(.threads(["a"]))
        XCTAssertNotEqual(revisions.revision(of: "a"), beforeEpoch)
    }

    /// The map guards a ten-entry cache; once it dwarfs that it is pure
    /// overhead, so it collapses to an epoch bump (over-invalidation is safe).
    func testTrackedThreadsCollapseToAnEpochBumpBeyondTheCap() {
        var revisions = ThreadContentRevisions()
        let ids = (0...ThreadContentRevisions.maxTrackedThreads).map { "t\($0)" }

        revisions.apply(.threads(Set(ids)))

        XCTAssertEqual(revisions.trackedThreadCount, 0)
        XCTAssertEqual(revisions.epoch, 1)
    }

    func testTrackedThreadsGrowWithinTheCap() {
        var revisions = ThreadContentRevisions()

        revisions.apply(.threads(["a", "b", "c"]))

        XCTAssertEqual(revisions.trackedThreadCount, 3)
        XCTAssertEqual(revisions.epoch, 0)
    }
}
