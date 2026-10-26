/// Timing limits describe the shipped, optimized app. Unoptimized test builds run several times
/// slower and shared CI machines add noise, so limits are only enforced in release builds
/// (`./scripts/test.sh -c release -Xswiftc -enable-testing`, which CI runs as well).
enum PerformanceBudget {
    static let isEnforced: Bool = {
        #if DEBUG
            false
        #else
            true
        #endif
    }()

    /// Wall-clock limit for guards against catastrophic (for example quadratic) slowdowns. Debug
    /// builds get ten times the budget so noisy runners do not fail, yet a real blow-up still does.
    static func limit(_ seconds: Double) -> Double {
        isEnforced ? seconds : seconds * 10
    }
}
