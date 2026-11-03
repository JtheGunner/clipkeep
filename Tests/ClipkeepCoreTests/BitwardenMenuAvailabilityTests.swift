import Testing

@testable import ClipkeepCore

@Suite struct BitwardenMenuAvailabilityTests {
    @Test func idleLockedVaultOffersOnlyUnlock() {
        let menu = BitwardenMenuAvailability(unlocked: false, canUnlock: true, work: nil)
        #expect(menu.unlockEnabled)
        #expect(!menu.transferEnabled)
        #expect(!menu.lockEnabled)
        #expect(menu.progressText == nil)
        #expect(menu.menuBarText == nil)
    }

    @Test func idleUnlockedVaultOffersTransferAndLock() {
        let menu = BitwardenMenuAvailability(unlocked: true, canUnlock: false, work: nil)
        #expect(!menu.unlockEnabled)
        #expect(menu.transferEnabled)
        #expect(menu.lockEnabled)
    }

    @Test func unlockingDisablesEverythingAndSaysSo() {
        let menu = BitwardenMenuAvailability(unlocked: false, canUnlock: true, work: .unlocking)
        #expect(!menu.unlockEnabled)
        #expect(!menu.transferEnabled)
        #expect(!menu.lockEnabled)
        #expect(menu.progressText?.contains("Entsperre") == true)
        #expect(menu.menuBarText == "Entsperre …")
    }

    @Test func transferringDisablesEverythingAndSaysSo() {
        let menu = BitwardenMenuAvailability(unlocked: true, canUnlock: false, work: .transferring)
        #expect(!menu.unlockEnabled)
        #expect(!menu.transferEnabled)
        #expect(!menu.lockEnabled)
        #expect(menu.progressText?.contains("Übertrage") == true)
        #expect(menu.menuBarText == "Übertrage …")
    }
}
