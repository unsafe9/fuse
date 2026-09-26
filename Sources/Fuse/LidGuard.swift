import AppKit
import IOKit.pwr_mgt
import LidGuardShared
import notify
import os

/// Fuse's side of lid-closed keep-awake: the lease the root lid guard follows, and the
/// install state of that helper.
///
/// The lease is a power assertion with a short timeout that Fuse renews while a timer
/// wants the lid guard. powerd drops it when Fuse exits for any reason, and it expires
/// if Fuse stops renewing it, so the daemon restores system sleep without depending on
/// Fuse to clean up.
final class LidGuard: ObservableObject {
    enum HelperStatus: Equatable {
        case checking
        case notInstalled
        case outdated
        case stopped
        case ready
    }

    static let shared = LidGuard()

    @Published private(set) var helperStatus: HelperStatus = .checking
    @Published private(set) var isRunningAdminTask = false

    private let log = Logger(subsystem: logSubsystem, category: "LidGuard")
    private let leaseTimeout: TimeInterval = 120
    private let leaseRenewInterval: TimeInterval = 30
    private var leaseID: IOPMAssertionID = 0
    private var renewTimer: Timer?
    private let statusQueue = DispatchQueue(label: "com.unsafe9.fuse.lidguard-status")

    private init() {}

    var holdsLease: Bool { leaseID != 0 }

    /// System sleep is still off on Fuse's behalf with no lease behind it, so the daemon
    /// is missing or failing and the user needs a way to turn sleep back on.
    var sleepLeftDisabled: Bool {
        !holdsLease && FileManager.default.fileExists(atPath: LidGuardContract.heldMarkerPath)
    }

    // MARK: - Lease

    func acquireLease() {
        guard !holdsLease, let id = createLeaseAssertion() else { return }
        leaseID = id
        notify_post(LidGuardContract.leaseChangedNotification)
        let timer = Timer(timeInterval: leaseRenewInterval, repeats: true) { [weak self] _ in
            self?.renewLease()
        }
        RunLoop.main.add(timer, forMode: .common)
        renewTimer = timer
    }

    func releaseLease() {
        renewTimer?.invalidate()
        renewTimer = nil
        guard holdsLease else { return }
        IOPMAssertionRelease(leaseID)
        leaseID = 0
        notify_post(LidGuardContract.leaseChangedNotification)
    }

    /// Creates the replacement before releasing the old assertion, so the daemon never
    /// sees a moment without a lease.
    private func renewLease() {
        guard holdsLease, let next = createLeaseAssertion() else { return }
        IOPMAssertionRelease(leaseID)
        leaseID = next
    }

    private func createLeaseAssertion() -> IOPMAssertionID? {
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: LidGuardContract.leaseAssertionName,
            kIOPMAssertionTimeoutKey: leaseTimeout,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard result == kIOReturnSuccess else {
            log.error("Lid guard lease assertion failed: \(result)")
            return nil
        }
        return id
    }

    // MARK: - Helper install state

    func refreshHelperStatus() {
        statusQueue.async { [weak self] in
            let status = Self.readHelperStatus()
            DispatchQueue.main.async {
                self?.helperStatus = status
            }
        }
    }

    private static func readHelperStatus() -> HelperStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: LidGuardContract.installedHelperPath),
              fileManager.fileExists(atPath: LidGuardContract.launchDaemonPlistPath) else {
            return .notInstalled
        }
        guard let reported = runForOutput(LidGuardContract.installedHelperPath, ["version"]),
              let version = Int(reported.trimmingCharacters(in: .whitespacesAndNewlines)),
              version >= LidGuardContract.helperVersion else {
            return .outdated
        }
        let job = runForOutput("/bin/launchctl", ["print", "system/\(LidGuardContract.label)"]) ?? ""
        return job.contains("state = running") ? .ready : .stopped
    }

    private static func runForOutput(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Administrator actions

    func installHelper() {
        runHelperAsAdministrator(
            "install",
            prompt: "Fuse wants to install its lid helper, which keeps your Mac awake with the lid closed while a timer runs.",
            failureTitle: "Couldn\u{2019}t install the lid helper"
        )
    }

    func uninstallHelper() {
        runHelperAsAdministrator(
            "uninstall",
            prompt: "Fuse wants to remove its lid helper.",
            failureTitle: "Couldn\u{2019}t remove the lid helper"
        )
    }

    func restoreSystemSleep() {
        runHelperAsAdministrator(
            "restore",
            prompt: "Fuse wants to turn system sleep back on.",
            failureTitle: "Couldn\u{2019}t turn system sleep back on"
        )
    }

    /// Runs the bundled helper as root through the standard administrator prompt. The
    /// helper performs the privileged work itself, so this is the only place Fuse asks
    /// for a password.
    private func runHelperAsAdministrator(_ command: String, prompt: String, failureTitle: String) {
        guard !isRunningAdminTask else { return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "FuseLidGuard") else {
            log.error("Bundled FuseLidGuard is missing.")
            showFailure(failureTitle, detail: "Fuse.app is missing its FuseLidGuard helper. Reinstall Fuse.")
            return
        }
        let shellCommand = "\(Self.shellQuoted(helper.path)) \(command)"
        let script = "do shell script \(Self.appleScriptString(shellCommand)) "
            + "with prompt \(Self.appleScriptString(prompt)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunningAdminTask = false
                self.refreshHelperStatus()
                // -128 is the user cancelling the password prompt.
                guard status != 0, !detail.contains("(-128)") else { return }
                self.log.error("FuseLidGuard \(command, privacy: .public) failed: \(detail, privacy: .public)")
                self.showFailure(failureTitle, detail: detail)
            }
        }

        isRunningAdminTask = true
        do {
            try process.run()
        } catch {
            isRunningAdminTask = false
            log.error("Could not run osascript: \(error.localizedDescription, privacy: .public)")
            showFailure(failureTitle, detail: error.localizedDescription)
        }
    }

    private func showFailure(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
