import Foundation

/// Bluetooth commands sent one at a time, each after the previous one's reply (or a timeout): sent 30 ms apart,
/// replies went missing and a command could land before the previous one had taken effect (verified on hardware).
/// A pure state machine, so it's unit-tested; `BLELink` performs its outputs and owns the timer.
struct BLECommandQueue {
    enum Step { case command([UInt8]), run(() -> Void) }
    enum Output { case send([UInt8]), run(() -> Void) }

    private(set) var steps: [Step] = []
    /// The command whose reply we're waiting for: command byte and subcommand (reply bytes 0 and 3).
    private(set) var awaiting: (command: UInt8, sub: UInt8)?

    var isIdle: Bool { steps.isEmpty && awaiting == nil }

    /// Add steps; returns what to do now (nothing if a command is still waiting for its reply).
    mutating func enqueue(_ new: [Step]) -> [Output] {
        let idle = isIdle
        steps += new
        return idle ? advance() : []
    }

    /// A reply arrived: if it answers the awaited command, returns the next outputs; nil if it's for something else.
    mutating func reply(_ r: [UInt8]) -> [Output]? {
        guard let a = awaiting, r.count >= 4, r[0] == a.command, r[3] == a.sub else { return nil }
        return advance()
    }

    /// The awaited reply didn't come in time: carry on with the next step.
    mutating func timedOut() -> [Output] { advance() }

    mutating func reset() { steps.removeAll(); awaiting = nil }

    /// Runs actions until the next command, which then waits for its reply.
    private mutating func advance() -> [Output] {
        awaiting = nil
        var out: [Output] = []
        while !steps.isEmpty {
            switch steps.removeFirst() {
            case .run(let action):
                out.append(.run(action))
            case .command(let c):
                out.append(.send(c))
                awaiting = (c[0], c.count > 3 ? c[3] : 0)
                return out
            }
        }
        return out
    }
}
