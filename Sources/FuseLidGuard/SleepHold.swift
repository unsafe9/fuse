import Foundation
import IOKit
import IOKit.ps
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
    /// policy. powerd owns that bit and sets it for desktop mode or a lid-close
    /// assertion; clearing it then starts a real sleep that powerd aborts only after the
    /// display has gone dark and the screen has locked, so skip it in both cases.
    private static func reapplyLidCloseSleep() {
        guard RootDomain.isClamshellClosed,
              !Assertions.anyAppliesOnLidClose(),
              !DesktopMode.isActive else { return }
        RootDomain.setClamshellSleepDisabled(true)
        RootDomain.setClamshellSleepDisabled(false)
    }
}

/// powerd's "desktop mode": an external display connected while on AC power, which keeps
/// a closed lid awake. WindowServer reports it to powerd privately, so this reads the
/// same inputs from the registry and the power source.
enum DesktopMode {
    static var isActive: Bool {
        onACPower && externalDisplayConnected
    }

    private static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return false
        }
        return (type as String) == kIOPMACPowerKey
    }

    /// Apple silicon publishes each external display pipe as an `IOMobileFramebufferShim`
    /// marked `external`, which carries `DisplayAttributes` only while a display is
    /// attached. Intel Macs have no such service; their kernel checks desktop mode itself
    /// before a clamshell sleep, so reporting false there keeps the reapply harmless.
    private static var externalDisplayConnected: Bool {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator
        ) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            if property(service, "external") as? Bool == true,
               property(service, "DisplayAttributes") != nil {
                return true
            }
        }
        return false
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
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
