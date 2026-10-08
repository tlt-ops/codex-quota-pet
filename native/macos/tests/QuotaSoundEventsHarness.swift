import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String,
                   file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else {
        fputs("\(file):\(line): \(message)\n", stderr)
        exit(1)
    }
}

private func sample(_ id: String, _ remaining: Int, _ updatedAt: TimeInterval,
                    reset: TimeInterval? = 1200, credits: Int? = 1,
                    bucket: String = "codex", kind: String = "primary",
                    duration: Int? = 300) -> QuotaSoundSample {
    QuotaSoundSample(bucketId: bucket, windowKind: kind,
                     windowDurationMins: duration,
                     usedPercent: Double(100 - remaining),
                     remainingPercent: remaining, resetsAt: reset,
                     availableCount: credits, sampleId: id,
                     updatedAt: updatedAt)
}

private func testFreshBaselineAndEveryIntegerPoint() {
    var detector = QuotaSoundDetector(startedAt: 1000.4)
    check(detector.accept(sample("old-cache", 90, 999), now: 1000.5) == .none,
          "pre-start cache is silent")
    check(detector.accept(sample("same-second-old-cache", 90, 1000.2), now: 1000.5) == .none,
          "pre-start cache in the launch second is silent")
    check(detector.nextResetAt == nil, "pre-start cache cannot schedule reset audio")
    check(detector.accept(sample("first", 100, 1000.6), now: 1000.6) == .none,
          "first fresh sample is a silent baseline")
    check(detector.nextResetAt == 1200, "future deadline is scheduled")
    check(detector.accept(sample("drop-three", 97, 1001), now: 1001)
          == QuotaSoundEvents(damageCount: 3, playXP: false),
          "three displayed points lost produce three hits")
    check(detector.accept(sample("drop-three", 97, 1001), now: 1002) == .none,
          "duplicate sample is silent")
    check(detector.accept(sample("first", 100, 1000), now: 1002) == .none,
          "an earlier seen sample is silent")
    check(detector.accept(sample("older-time", 96, 999), now: 1002) == .none,
          "stale timestamp is silent")
    check(detector.accept(sample("unchanged", 97, 1002), now: 1002) == .none,
          "unchanged displayed quota is silent")
}

private func testWindowIdentityAndSameSecondSnapshots() {
    var detector = QuotaSoundDetector(startedAt: 1000)
    check(detector.accept(sample("a", 80, 1000), now: 1000) == .none,
          "baseline")
    check(detector.accept(sample("other-window", 40, 1000, kind: "secondary"), now: 1000) == .none,
          "window switch cannot create a 40-point loss")
    check(detector.accept(sample("b", 39, 1000, kind: "secondary"), now: 1000)
          == QuotaSoundEvents(damageCount: 1, playXP: false),
          "distinct snapshots within one timestamp second are compared")
    check(detector.accept(sample("duration-switch", 70, 1001, kind: "secondary", duration: 10080),
                          now: 1001) == .none,
          "duration switch starts a silent baseline")
    check(detector.accept(sample("bucket-switch", 5, 1002, bucket: "legacy"), now: 1002) == .none,
          "bucket switch starts a silent baseline")
}

private func testFutureDeadlineCorrectionStillCountsUsage() {
    var detector = QuotaSoundDetector(startedAt: 1000)
    check(detector.accept(sample("base", 53, 1000, reset: 2000), now: 1000) == .none,
          "baseline")
    check(detector.accept(sample("deadline-extended", 52, 1001, reset: 2100), now: 1001)
          == QuotaSoundEvents(damageCount: 1, playXP: false),
          "a future deadline correction cannot hide a displayed one-point loss")
    check(detector.nextResetAt == 2100, "the corrected future deadline is scheduled")
}

private func testCreditsAndFreeRecharge() {
    var detector = QuotaSoundDetector(startedAt: 1000)
    check(detector.accept(sample("base", 50, 1000, credits: 1), now: 1000) == .none,
          "baseline")
    check(detector.accept(sample("credit-down", 50, 1001, credits: 0), now: 1001) == .none,
          "credit consumption without quota gain is silent")
    check(detector.accept(sample("free-recharge", 60, 1002, credits: 2), now: 1002)
          == QuotaSoundEvents(damageCount: 0, playXP: true),
          "quota recharge and credit increase coalesce to one XP")
    check(detector.accept(sample("after-recharge", 59, 1003, credits: 2), now: 1003)
          == QuotaSoundEvents(damageCount: 1, playXP: false),
          "later usage is still counted")
    check(detector.accept(sample("more-credits", 59, 1004, credits: 3), now: 1004)
          == QuotaSoundEvents(damageCount: 0, playXP: true),
          "known credit count increase plays XP")
    check(detector.accept(sample("unknown-credits", 59, 1005, credits: nil), now: 1005) == .none,
          "unknown credit count is silent")
    check(detector.accept(sample("known-again", 59, 1006, credits: 5), now: 1006) == .none,
          "unknown to known is not a proven increase")
}

private func testTimerDeadlineAndConfirmation() {
    var detector = QuotaSoundDetector(startedAt: 1000)
    check(detector.accept(sample("base", 40, 1000), now: 1000) == .none,
          "baseline")
    check(!detector.markResetDue(now: 1199.99), "timer cannot fire early")
    check(detector.markResetDue(now: 1200), "timer fires exactly at deadline")
    check(!detector.markResetDue(now: 1200), "timer fires only once")
    check(detector.accept(sample("post-deadline-use", 39, 1200, reset: 1200), now: 1200)
          == QuotaSoundEvents(damageCount: 1, playXP: false),
          "one displayed point lost after timer fires still plays one hit")
    check(detector.accept(sample("quota-lag", 80, 1200.1,
                                 reset: 1200, credits: 1), now: 1200.1)
          == .none, "quota-only confirmation does not repeat the deadline XP")
    check(detector.accept(sample("credits-increase", 80, 1200.2,
                                 reset: 1200, credits: 2), now: 1200.2)
          == QuotaSoundEvents(damageCount: 0, playXP: true),
          "a separate credit increase plays once despite old overdue timestamp")
    check(detector.accept(sample("same-credits", 80, 1200.3,
                                 reset: 1200, credits: 2), now: 1200.3)
          == .none, "same credit count does not repeat XP")
    check(detector.accept(sample("confirmed", 100, 1200.4, reset: 1500, credits: 2), now: 1200.4)
          == .none, "rollover confirmation does not repeat XP or fake damage")
    check(detector.nextResetAt == 1500, "new future reset is scheduled")
    check(detector.accept(sample("new-use", 99, 1201, reset: 1500, credits: 2), now: 1201)
          == QuotaSoundEvents(damageCount: 1, playXP: false),
          "usage after confirmation is counted")
}

private func testDeadlineSeenInFreshSnapshotWithoutTimer() {
    var detector = QuotaSoundDetector(startedAt: 1000)
    check(detector.accept(sample("base", 20, 1000), now: 1000) == .none,
          "baseline")
    check(detector.accept(sample("at-deadline", 18, 1200, reset: 1200), now: 1200)
          == QuotaSoundEvents(damageCount: 0, playXP: true),
          "first post-deadline snapshot plays one XP and no damage")
    check(detector.accept(sample("same-overdue", 17, 1201, reset: 1200), now: 1201)
          == QuotaSoundEvents(damageCount: 1, playXP: false),
          "an overdue timestamp does not suppress later usage indefinitely")
    check(detector.accept(sample("rollover-confirmed", 100, 1202, reset: 1500), now: 1202)
          == .none, "late rollover confirmation remains silent")
}

private func testStartupOverdueAndErrorGap() {
    var detector = QuotaSoundDetector(startedAt: 1300)
    check(detector.accept(sample("overdue-baseline", 20, 1300, reset: 1200), now: 1300)
          == .none, "old overdue deadline cannot chime on startup")
    check(detector.nextResetAt == nil, "old deadline is not scheduled")
    check(detector.accept(sample("still-overdue", 20, 1301, reset: 1200), now: 1301)
          == .none, "old overdue deadline cannot chime on later reads")
    check(detector.accept(sample("real-recharge", 90, 1302, reset: 1600), now: 1302)
          == QuotaSoundEvents(damageCount: 0, playXP: true),
          "an observed recharge after overdue startup still plays XP")

    detector.noteFailure(updatedAt: 1303)
    check(detector.nextResetAt == nil, "error cancels reset timer")
    check(detector.accept(sample("stale-after-error", 30, 1302, reset: 1600), now: 1304)
          == .none, "pre-error sample cannot restart comparison")
    check(detector.accept(sample("recovered", 40, 1304, reset: 1600), now: 1304)
          == .none, "first recovery sample is a silent baseline")
    check(detector.accept(sample("recovered-drop", 39, 1305, reset: 1600), now: 1305)
          == QuotaSoundEvents(damageCount: 1, playXP: false),
          "the following fresh sample may play")
}

@main
struct Runner {
    static func main() {
        testFreshBaselineAndEveryIntegerPoint()
        testWindowIdentityAndSameSecondSnapshots()
        testFutureDeadlineCorrectionStillCountsUsage()
        testCreditsAndFreeRecharge()
        testTimerDeadlineAndConfirmation()
        testDeadlineSeenInFreshSnapshotWithoutTimer()
        testStartupOverdueAndErrorGap()
        print("QuotaSoundEvents: 7 scenario groups passed")
    }
}
