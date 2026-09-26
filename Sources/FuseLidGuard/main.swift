import Foundation
import LidGuardShared

let usage = """
usage: FuseLidGuard <command>
  daemon     run the lid guard (launchd starts this)
  install    install and start the daemon (root)
  uninstall  stop and remove the daemon, restoring system sleep (root)
  restore    turn system sleep back on (root)
  version    print the helper version
"""

switch CommandLine.arguments.dropFirst().first {
case "daemon":
    let daemon = LidGuardDaemon()
    daemon.run()
case "install":
    exit(Installer.install())
case "uninstall":
    exit(Installer.uninstall())
case "restore":
    guard Installer.requireRoot() else { exit(77) }
    exit(SleepHold.release() ? 0 : 1)
case "version":
    print(LidGuardContract.helperVersion)
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
