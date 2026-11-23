import Foundation
import Testing
@testable import Olaz

@Suite(.serialized) struct InstanceLockTests {
    @Test func secondHolderIsRefusedUntilRelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-lock-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("instance.lock")
        defer { InstanceLock.release(); try? FileManager.default.removeItem(at: dir) }

        #expect(InstanceLock.acquire(at: url))
        #expect(InstanceLock.acquire(at: url))   // re-entrant in the holding process

        // Another open file description (what a second process gets) cannot take it.
        let other = open(url.path, O_RDWR)
        #expect(other >= 0)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) != 0)

        InstanceLock.release()
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0)
    }
}
