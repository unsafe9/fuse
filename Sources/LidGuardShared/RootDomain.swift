import Foundation
import IOKit

/// The `IOPMrootDomain` state that the lid guard reads and writes.
public enum RootDomain {
    /// `IOPMLibDefs.h`: `kPMSetClamshellSleepState`. The kernel accepts it from any local
    /// user, but powerd rewrites the same bit whenever it re-evaluates lid-close
    /// assertions, so on its own it cannot keep a closed lid awake.
    private static let clamshellSleepStateSelector: UInt32 = 12

    public static var isSleepDisabled: Bool {
        boolProperty("SleepDisabled") ?? false
    }

    public static var isClamshellClosed: Bool {
        boolProperty("AppleClamshellState") ?? false
    }

    @discardableResult
    public static func setClamshellSleepDisabled(_ disabled: Bool) -> kern_return_t {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return kIOReturnNotFound }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == kIOReturnSuccess else { return opened }
        defer { IOServiceClose(connection) }

        var input: UInt64 = disabled ? 1 : 0
        return IOConnectCallScalarMethod(connection, clamshellSleepStateSelector, &input, 1, nil, nil)
    }

    private static func boolProperty(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool
    }
}
