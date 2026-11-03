/// What the Bitwarden menu is busy with, if anything.
public enum BitwardenWork: Sendable, Equatable {
    case unlocking
    case transferring
}

/// Which Bitwarden menu items can be used. While work is running nothing can be started again,
/// and the menu says what is going on.
public struct BitwardenMenuAvailability: Sendable, Equatable {
    public let unlockEnabled: Bool
    public let transferEnabled: Bool
    public let lockEnabled: Bool
    /// Shown next to a spinner while work is running; nil when idle.
    public let progressText: String?

    public init(unlocked: Bool, canUnlock: Bool, work: BitwardenWork?) {
        unlockEnabled = work == nil && canUnlock
        transferEnabled = work == nil && unlocked
        lockEnabled = work == nil && unlocked
        progressText =
            switch work {
            case .unlocking: "Entsperre und übertrage Secrets …"
            case .transferring: "Übertrage Secrets …"
            case nil: nil
            }
    }
}
