import Foundation

/// One successfully refreshed quota snapshot. The values come from the same
/// rate-limit window that supplies the three visible lines in the pet bubble.
struct QuotaSoundSample {
    let bucketId: String
    let windowKind: String
    let windowDurationMins: Int?
    let usedPercent: Double
    let remainingPercent: Int
    let resetsAt: TimeInterval?
    let availableCount: Int?
    let sampleId: String
    let updatedAt: TimeInterval

    init(bucketId: String, windowKind: String, windowDurationMins: Int?,
         usedPercent: Double, remainingPercent: Int, resetsAt: TimeInterval?,
         availableCount: Int?, sampleId: String, updatedAt: TimeInterval) {
        self.bucketId = bucketId
        self.windowKind = windowKind
        self.windowDurationMins = windowDurationMins
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.availableCount = availableCount
        self.sampleId = sampleId
        self.updatedAt = updatedAt
    }

    fileprivate func hasSameWindow(as other: QuotaSoundSample) -> Bool {
        bucketId == other.bucketId && windowKind == other.windowKind
            && windowDurationMins == other.windowDurationMins
    }

    fileprivate var isValid: Bool {
        let validDuration = windowDurationMins.map { $0 > 0 } ?? true
        let validCredits = availableCount.map { $0 >= 0 } ?? true
        let validReset = resetsAt.map { $0.isFinite && $0 > 0 } ?? true
        return !bucketId.isEmpty && !windowKind.isEmpty && !sampleId.isEmpty
            && updatedAt.isFinite && usedPercent.isFinite
            && (0...100).contains(remainingPercent)
            && validDuration && validCredits && validReset
    }
}

struct QuotaSoundEvents: Equatable {
    let damageCount: Int
    let playXP: Bool

    static let none = QuotaSoundEvents(damageCount: 0, playXP: false)
}

/// Pure event detector: no audio, timers, file reads, or app state. Each
/// displayed integer percentage point lost produces one damage event; one
/// recharge, credit increase, or reset deadline produces at most one XP event.
struct QuotaSoundDetector {
    private let startedAt: TimeInterval
    private var previous: QuotaSoundSample?
    private var latestUpdatedAt: TimeInterval?
    private var seenSampleIds = Set<String>()
    private var recentSampleIds = [String]()
    private var consumedBoundaryAt: TimeInterval?
    private var notifiedResetAt: TimeInterval?

    private(set) var nextResetAt: TimeInterval?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    mutating func accept(_ sample: QuotaSoundSample, now: TimeInterval) -> QuotaSoundEvents {
        guard now.isFinite, sample.isValid,
              // The JSON timestamp keeps fractional seconds, so a cached
              // snapshot made just before launch cannot become the baseline.
              sample.updatedAt >= startedAt,
              sample.updatedAt >= (latestUpdatedAt ?? -Double.infinity),
              !seenSampleIds.contains(sample.sampleId) else { return .none }

        remember(sample)
        guard let old = previous, sample.hasSameWindow(as: old) else {
            makeBaseline(sample, now: now)
            return .none
        }

        let oldReset = old.resetsAt
        let crossedBoundary = oldReset.map { $0 <= now && consumedBoundaryAt != $0 } ?? false
        let resetAdvanced = oldReset.flatMap { oldDate in
            sample.resetsAt.map { $0 > oldDate }
        } ?? false
        let resetAdvancedAfterDeadline = resetAdvanced
            && (oldReset.map { $0 <= now } ?? false)
        let quotaGained = sample.remainingPercent > old.remainingPercent
        let creditsGained = old.availableCount.flatMap { oldCount in
            sample.availableCount.map { $0 > oldCount }
        } ?? false
        // The reset and its quota confirmation may arrive in several reads
        // while the server still reports the old, expired deadline. A credit
        // increase is a separate event, even if that timestamp is unchanged.
        let resetAlreadyPlayed = oldReset.map {
            notifiedResetAt == $0 && ($0 <= now || resetAdvanced)
        } ?? false

        let playXP = creditsGained
            || (!resetAlreadyPlayed && (crossedBoundary || quotaGained))
        let damageCount: Int
        if crossedBoundary || resetAdvancedAfterDeadline || quotaGained {
            damageCount = 0
        } else {
            damageCount = max(0, old.remainingPercent - sample.remainingPercent)
        }

        if (crossedBoundary || resetAdvanced), playXP {
            notifiedResetAt = oldReset
        }
        previous = sample
        if let reset = sample.resetsAt, reset <= now {
            // Consume an already overdue timestamp once. Until the server
            // supplies a new deadline, subsequent usage changes are ordinary.
            consumedBoundaryAt = reset
            nextResetAt = nil
        } else {
            consumedBoundaryAt = nil
            nextResetAt = sample.resetsAt
        }
        return QuotaSoundEvents(damageCount: damageCount, playXP: playXP)
    }

    /// Called by the App's timer at the exact known reset deadline. Returning
    /// true means play XP once. A later API confirmation of this reset is mute.
    mutating func markResetDue(now: TimeInterval) -> Bool {
        guard now.isFinite, let deadline = nextResetAt,
              now >= deadline else { return false }
        nextResetAt = nil
        // The timer itself crossed this boundary. Usage observed afterward
        // belongs to ordinary comparison, including a one-point drop.
        consumedBoundaryAt = deadline
        guard notifiedResetAt != deadline else { return false }
        notifiedResetAt = deadline
        return true
    }

    /// A newly written error snapshot breaks the comparison chain. The first
    /// fresh successful snapshot after it establishes a silent baseline.
    mutating func noteFailure(updatedAt: TimeInterval? = nil) {
        if let updatedAt, updatedAt.isFinite {
            latestUpdatedAt = max(latestUpdatedAt ?? -Double.infinity, updatedAt)
        }
        resetBaseline()
    }

    mutating func resetBaseline() {
        previous = nil
        consumedBoundaryAt = nil
        notifiedResetAt = nil
        nextResetAt = nil
    }

    private mutating func makeBaseline(_ sample: QuotaSoundSample, now: TimeInterval) {
        previous = sample
        notifiedResetAt = nil
        if let reset = sample.resetsAt, reset <= now {
            // Starting after a stale displayed deadline must not chime.
            consumedBoundaryAt = reset
            nextResetAt = nil
        } else {
            consumedBoundaryAt = nil
            nextResetAt = sample.resetsAt
        }
    }

    private mutating func remember(_ sample: QuotaSoundSample) {
        latestUpdatedAt = sample.updatedAt
        seenSampleIds.insert(sample.sampleId)
        recentSampleIds.append(sample.sampleId)
        if recentSampleIds.count > 128 {
            let expired = recentSampleIds.removeFirst()
            seenSampleIds.remove(expired)
        }
    }
}
