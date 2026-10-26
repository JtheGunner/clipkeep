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
}
