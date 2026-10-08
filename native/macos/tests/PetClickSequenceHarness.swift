import AppKit

private func labels(_ actions: [PetClickSequence.Action]) -> [String] {
    actions.map { action in
        switch action {
        case .launch(let launch): return "launch:\(Int(launch.point.x))"
        case .wheel(let point): return "wheel:\(Int(point.x))"
        }
    }
}

private func expect(_ actions: [PetClickSequence.Action], _ expected: [String],
                    _ caseName: String) {
    let actual = labels(actions)
    precondition(actual == expected, "\(caseName): expected \(expected), got \(actual)")
}

private func tap(_ sequence: inout PetClickSequence, down: TimeInterval,
                 up: TimeInterval, count: Int, x: CGFloat) -> [PetClickSequence.Action] {
    let started = sequence.beginCharacter(at: down, clickCount: count)
    let finished = sequence.endCharacter(at: up, point: NSPoint(x: x, y: 40),
                                         duration: up - down, valid: true,
                                         longPress: false)
    return started + finished
}

@main
private struct PetClickSequenceHarness {
    static func main() {
        let interval: TimeInterval = 0.5

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [], "single buffered")
            expect(sequence.resolveDue(at: 0.54), [], "single before deadline")
            expect(sequence.resolveDue(at: 0.56), ["launch:101"], "single launch")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [], "double first")
            expect(tap(&sequence, down: 0.1, up: 0.12, count: 2, x: 102), [], "double second")
            expect(sequence.resolveDue(at: 0.64), [], "double before deadline")
            expect(sequence.resolveDue(at: 0.66), ["wheel:102"], "exact double wheel")
            expect(sequence.resolveDue(at: 1.0), [], "double only once")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [], "triple first")
            expect(tap(&sequence, down: 0.1, up: 0.12, count: 2, x: 102), [], "triple second")
            expect(sequence.beginCharacter(at: 0.2, clickCount: 3),
                   ["launch:101", "launch:102"], "third down cancels wheel")
            expect(sequence.resolveDue(at: 0.7), [], "third held cannot show wheel")
            expect(sequence.endCharacter(at: 0.72, point: NSPoint(x: 103, y: 40),
                                         duration: 0.52, valid: true, longPress: true),
                   ["launch:103"], "held third launches")
            expect(tap(&sequence, down: 0.74, up: 0.76, count: 4, x: 104),
                   ["launch:104"], "fourth remains in streak")
            expect(tap(&sequence, down: 0.84, up: 0.86, count: 5, x: 105),
                   ["launch:105"], "fifth remains in streak")
            expect(sequence.resolveDue(at: 1.5), [], "multi-click has no wheel")
            expect(tap(&sequence, down: 1.6, up: 1.62, count: 1, x: 106),
                   [], "sequence resets after gap")
            expect(tap(&sequence, down: 1.7, up: 1.72, count: 2, x: 107),
                   [], "fresh double buffered")
            expect(sequence.resolveDue(at: 2.26), ["wheel:107"],
                   "fresh double wheel")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [],
                   "boundary first")
            expect(tap(&sequence, down: 0.1, up: 0.45, count: 2, x: 102), [],
                   "boundary second held below long-press threshold")
            // More than one interval has passed since the second mouseDown,
            // but the third press is still within the interval after mouseUp.
            expect(sequence.beginCharacter(at: 0.7, clickCount: 3),
                   ["launch:101", "launch:102"], "third near boundary cancels wheel")
            expect(sequence.endCharacter(at: 0.72, point: NSPoint(x: 103, y: 40),
                                         duration: 0.02, valid: true, longPress: false),
                   ["launch:103"], "boundary third launch")
            expect(sequence.resolveDue(at: 1.5), [], "boundary has no wheel")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [],
                   "late timer first")
            expect(tap(&sequence, down: 0.1, up: 0.45, count: 2, x: 102), [],
                   "late timer second")
            // The run loop has not delivered the due timer, but AppKit says
            // this is still click three. It must win over wheel resolution.
            expect(sequence.beginCharacter(at: 1.0, clickCount: 3),
                   ["launch:101", "launch:102"], "late third cancels wheel")
            expect(sequence.endCharacter(at: 1.02, point: NSPoint(x: 103, y: 40),
                                         duration: 0.02, valid: true, longPress: false),
                   ["launch:103"], "late third launch")
            expect(sequence.resolveDue(at: 2), [], "late timer remains canceled")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [], "drag first")
            expect(sequence.beginCharacter(at: 0.1, clickCount: 2), [], "drag second down")
            expect(sequence.endCharacter(at: 0.14, point: NSPoint(x: 102, y: 40),
                                         duration: 0.04, valid: false, longPress: false),
                   ["launch:101"], "dragged second restores first")
            expect(sequence.resolveDue(at: 1), [], "drag never opens wheel")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [], "hold first")
            expect(sequence.beginCharacter(at: 0.1, clickCount: 2), [], "hold second down")
            expect(sequence.endCharacter(at: 0.8, point: NSPoint(x: 102, y: 40),
                                         duration: 0.7, valid: true, longPress: true),
                   ["launch:101", "launch:102"], "held second keeps charge")
            expect(sequence.resolveDue(at: 1.5), [], "hold never opens wheel")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [], "bubble first")
            expect(tap(&sequence, down: 0.1, up: 0.12, count: 2, x: 102), [], "bubble second")
            expect(sequence.interrupt(at: 0.2), ["launch:101", "launch:102"],
                   "bubble or right click interrupts pair")
            expect(sequence.resolveDue(at: 1), [], "interrupted pair has no delayed wheel")
        }

        do {
            var sequence = PetClickSequence(doubleClickInterval: interval)
            expect(tap(&sequence, down: 0, up: 0.02, count: 1, x: 101), [], "mismatch first")
            expect(sequence.beginCharacter(at: 0.1, clickCount: 1),
                   ["launch:101"], "AppKit spatial mismatch flushes first")
            expect(sequence.endCharacter(at: 0.12, point: NSPoint(x: 102, y: 40),
                                         duration: 0.02, valid: true, longPress: false),
                   ["launch:102"], "mismatched second launches")
            expect(sequence.resolveDue(at: 1), [], "mismatch has no wheel")
        }

        print("PetClickSequenceHarness PASS")
    }
}
