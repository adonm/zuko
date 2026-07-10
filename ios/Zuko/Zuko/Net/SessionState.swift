import Foundation

enum SessionFailureRecovery: Equatable {
    case retry
    case rePair
    case none
}

enum SessionStatus: Equatable {
    case idle
    case connecting
    case reconnecting(attempt: Int, delaySeconds: Int, reason: String)
    case connected
    case disconnected(String)
    case failed(reason: String, recovery: SessionFailureRecovery)
}

struct ReconnectBackoff {
    struct Step {
        let attempt: Int
        let delayNanoseconds: UInt64

        var delaySeconds: Int {
            max(1, Int(delayNanoseconds / 1_000_000_000))
        }
    }

    private static let baseDelay: UInt64 = 1_000_000_000
    private static let maxDelay: UInt64 = 15_000_000_000

    private(set) var attempt = 0

    mutating func recordFailure() -> Step {
        attempt += 1
        return Step(
            attempt: attempt,
            delayNanoseconds: Self.delay(forAttempt: attempt)
        )
    }

    mutating func reset() {
        attempt = 0
    }

    private static func delay(forAttempt attempt: Int) -> UInt64 {
        let shift = UInt64(min(max(attempt - 1, 0), 4))
        return min(baseDelay << shift, maxDelay)
    }
}
