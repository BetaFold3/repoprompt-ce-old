import Darwin
import Foundation

/// Optional launch-ownership hooks for one managed child launch (lossless restart R6).
///
/// A launcher that receives an owner calls, in order and at most once each:
/// 1. `prepareSpawn()` immediately before the actual spawn. A throw refuses the launch: nothing is
///    spawned and the launcher rethrows the owner's error (never a fresh unowned fallback).
/// 2. `spawnFailed()` when the spawn itself failed after a successful prepare (no process exists).
/// 3. `commitSpawn(pid:processGroupID:)` with the exact spawned root before any stdin write. A
///    throw makes the launcher terminate and reap that root without writing to it, report
///    `rootReaped(pid:confirmed:)`, and rethrow.
/// 4. `rootReaped(pid:confirmed:)` once the launcher finished waiting on the exact root. `confirmed`
///    is true only when the launcher's own `waitpid` returned that pid; `ECHILD`, a wait failure or
///    an expired grace period report `false` (write authority still ends, but it is not exit
///    proof). A confirmed reap is evidence for that process lifetime only; it never proves the
///    family (descendants) exited.
///
/// Without an owner, launches are unchanged (and `ProcessLauncher.spawn(runtimeID: nil)` keeps
/// passing the environment through unchanged).
package protocol ProcessLaunchOwnership: AnyObject, Sendable {
    /// Reserves the launch and returns the runtime marker to place in the child environment.
    func prepareSpawn() async throws -> UUID
    /// The spawn failed after a successful prepare; no child exists.
    func spawnFailed() async
    /// Commits the spawned root's identity before any stdin write.
    func commitSpawn(pid: pid_t, processGroupID: pid_t?) async throws
    /// The launcher stopped waiting on the exact root `pid`; `confirmed` when it reaped it itself.
    func rootReaped(pid: pid_t, confirmed: Bool) async
}
