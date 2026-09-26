import Foundation
import LidGuardShared

/// Installs the helper as a system LaunchDaemon outside the app bundle, so deleting
/// Fuse.app cannot strand a disabled sleep setting without its guard.
enum Installer {
    static func requireRoot() -> Bool {
        guard getuid() == 0 else {
            fail("must run as root")
            return false
        }
        return true
    }

    static func install() -> Int32 {
        guard requireRoot() else { return 77 }
        guard let source = currentExecutable() else {
            fail("cannot locate this executable")
            return 1
        }
        stopDaemon()

        let fileManager = FileManager.default
        let helper = URL(fileURLWithPath: LidGuardContract.installedHelperPath)
        let rootOwned: (Int) -> [FileAttributeKey: Any] = { mode in
            [.posixPermissions: mode, .ownerAccountID: 0, .groupOwnerAccountID: 0]
        }
        do {
            try fileManager.createDirectory(
                at: helper.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: rootOwned(0o755)
            )
            if source.path != helper.path {
                // Copy the bytes rather than the file so no quarantine attribute follows.
                let staged = helper.deletingLastPathComponent()
                    .appendingPathComponent(".\(LidGuardContract.label).new")
                try? fileManager.removeItem(at: staged)
                try Data(contentsOf: source).write(to: staged)
                try fileManager.setAttributes(rootOwned(0o755), ofItemAtPath: staged.path)
                guard rename(staged.path, helper.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            let job: [String: Any] = [
                "Label": LidGuardContract.label,
                "ProgramArguments": [LidGuardContract.installedHelperPath, "daemon"],
                "RunAtLoad": true,
                "KeepAlive": true,
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try plist.write(to: URL(fileURLWithPath: LidGuardContract.launchDaemonPlistPath), options: .atomic)
            try fileManager.setAttributes(rootOwned(0o644), ofItemAtPath: LidGuardContract.launchDaemonPlistPath)
        } catch {
            fail("could not install files: \(error.localizedDescription)")
            return 1
        }

        guard startDaemon() else {
            fail("launchd refused to start \(LidGuardContract.label); allow it in System Settings > General > Login Items")
            return 1
        }
        print("Installed \(LidGuardContract.label).")
        return 0
    }

    static func uninstall() -> Int32 {
        guard requireRoot() else { return 77 }
        // The daemon restores system sleep itself when launchd stops it.
        stopDaemon()
        if SleepHold.isHeld, !SleepHold.release() {
            fail("could not restore system sleep; run: sudo pmset -a disablesleep 0")
        }
        let fileManager = FileManager.default
        for path in [LidGuardContract.launchDaemonPlistPath, LidGuardContract.installedHelperPath] {
            try? fileManager.removeItem(atPath: path)
        }
        let markerDirectory = URL(fileURLWithPath: LidGuardContract.heldMarkerPath).deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: markerDirectory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: markerDirectory)
        }
        print("Removed \(LidGuardContract.label).")
        return 0
    }

    private static func currentExecutable() -> URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private static var isLoaded: Bool {
        Tool.run("/bin/launchctl", ["print", "system/\(LidGuardContract.label)"]) == 0
    }

    private static func stopDaemon() {
        guard isLoaded else { return }
        Tool.run("/bin/launchctl", ["bootout", "system/\(LidGuardContract.label)"], timeout: 30)
        let deadline = Date().addingTimeInterval(10)
        while isLoaded, Date() < deadline {
            usleep(200_000)
        }
    }

    /// launchd can briefly refuse a bootstrap right after a bootout, so retry.
    private static func startDaemon() -> Bool {
        for attempt in 0..<5 {
            if attempt > 0 { sleep(1) }
            if Tool.run("/bin/launchctl", ["bootstrap", "system", LidGuardContract.launchDaemonPlistPath]) == 0 {
                return true
            }
        }
        return false
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("FuseLidGuard: \(message)\n".utf8))
    }
}
