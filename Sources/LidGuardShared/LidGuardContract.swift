/// The contract between Fuse and its root lid-guard daemon.
///
/// The daemon keeps system sleep disabled exactly while some process holds a power
/// assertion named `leaseAssertionName`, so Fuse and every installed daemon version
/// must agree on these values.
public enum LidGuardContract {
    public static let label = "com.unsafe9.fuse.lidguard"

    /// Bump when an installed daemon must be replaced for the current Fuse to work.
    public static let helperVersion = 2

    public static let leaseAssertionName = "Fuse lid-closed keep-awake"

    /// Darwin notification Fuse posts after taking or dropping the lease, so the daemon
    /// reacts at once instead of on its next poll.
    public static let leaseChangedNotification = "com.unsafe9.fuse.lidguard.lease-changed"

    public static let installedHelperPath = "/Library/PrivilegedHelperTools/com.unsafe9.fuse.lidguard"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.unsafe9.fuse.lidguard.plist"

    /// Exists while the daemon has system sleep disabled on Fuse's behalf. Like the
    /// `pmset disablesleep` setting it records, it survives reboots.
    public static let heldMarkerPath = "/Library/Application Support/Fuse/lidguard-held"
}
