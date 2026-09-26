import Foundation
import LidGuardShared

/// The system-wide sleep switch (`pmset disablesleep`) and the marker recording that
/// the lid guard, rather than the user, turned it on.
enum SleepHold {
    static var isHeld: Bool {
        FileManager.default.fileExists(atPath: LidGuardContract.heldMarkerPath)
    }

    /// Writes the marker before flipping the switch, so a crash in between still leaves
    /// a record for the next reconcile to clean up.
    static func take() -> Bool {
        let marker = URL(fileURLWithPath: LidGuardContract.heldMarkerPath)
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try Data().write(to: marker)
        } catch {
            return false
        }
        guard Tool.run("/usr/bin/pmset", ["-a", "disablesleep", "1"]) == 0 else {
            try? FileManager.default.removeItem(at: marker)
            return false
        }
        return true
    }

    static func release() -> Bool {
        guard Tool.run("/usr/bin/pmset", ["-a", "disablesleep", "0"]) == 0 else { return false }
        // powerd applies the setting to the kernel asynchronously.
        let deadline = Date().addingTimeInterval(3)
        while RootDomain.isSleepDisabled, Date() < deadline {
            usleep(100_000)
        }
        try? FileManager.default.removeItem(atPath: LidGuardContract.heldMarkerPath)
        reapplyLidCloseSleep()
        return true
    }

    /// Turning `SleepDisabled` off does not make the kernel re-check a lid that is
    /// already closed, so a timer ending with the lid shut would leave the Mac awake. A
    /// 1 -> 0 transition of the clamshell bit makes the kernel apply its own lid-close
    /// policy, which still keeps an external display on AC awake. Skipped while another
    /// process holds a lid-close assertion, because powerd wants the bit set then.
    private static func reapplyLidCloseSleep() {
        guard RootDomain.isClamshellClosed, !Assertions.anyAppliesOnLidClose() else { return }
        RootDomain.setClamshellSleepDisabled(true)
        RootDomain.setClamshellSleepDisabled(false)
    }
}

enum Tool {
    /// Runs a tool to completion and returns its exit status, or nil if it could not
    /// start or overran `timeout`.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}
