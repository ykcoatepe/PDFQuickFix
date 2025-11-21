import Foundation

actor AsyncThrottle {
    private let interval: Duration
    private var lastFire: ContinuousClock.Instant?

    init(_ interval: Duration) {
        self.interval = interval
    }

    func run(_ op: @escaping @Sendable () async -> Void) {
        Task {
            let now = ContinuousClock.now
            if let last = lastFire {
                let delta = now - last
                if delta < interval {
                    try? await Task.sleep(for: interval - delta)
                }
            }
            lastFire = ContinuousClock.now
            await op()
        }
    }
}
