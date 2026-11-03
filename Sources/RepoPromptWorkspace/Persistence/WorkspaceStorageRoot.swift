import Foundation
import RepoPromptShared

/// The single authority for the default per-workspace storage root
/// (`<Application Support>/RepoPrompt CE/Workspaces` in production).
///
/// Only the `Workspaces` tree is redirected here. The rest of Application Support (MCP sockets,
/// events, terminal records, approval state) stays on `MCPFilesystemIdentity.applicationSupportRootURL()`
/// because helper subprocesses share it with the app.
///
/// Precedence, highest first:
/// 1. an explicit root injected by the caller (a workspace's `customStoragePath`, the global custom
///    storage location, or a test-injected root);
/// 2. the `RPCE_WORKSPACES_ROOT_OVERRIDE` environment variable (an absolute path), honored only in
///    DEBUG builds or under XCTest, so a release install never changes where it stores workspaces
///    because of the environment;
/// 3. under XCTest, one stable per-process temporary root, so tests never write the live store;
/// 4. the production root.
///
/// Resolution never creates directories; writers create intermediates when they first persist.
package enum WorkspaceStorageRoot {
    package static let environmentOverrideKey = "RPCE_WORKSPACES_ROOT_OVERRIDE"
    static let workspacesDirectoryName = "Workspaces"

    package enum Source: String, Equatable {
        case injected
        case environmentOverride
        case xctestTemporary
        case production
    }

    package struct Resolution: Equatable {
        package let url: URL
        package let source: Source
    }

    /// The default `Workspaces` root for this process.
    package static var defaultRootURL: URL {
        resolve().url
    }

    /// Resolves the root by precedence. Every input is injectable so the order is testable without
    /// touching the process environment or the live store.
    package static func resolve(
        injected: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        environmentOverrideAllowed: Bool = Self.environmentOverrideAllowed,
        isRunningUnderXCTest: Bool = Self.isRunningUnderXCTest,
        xctestTemporaryRoot: @autoclosure () -> URL = Self.xctestTemporaryRootURL,
        productionRoot: @autoclosure () -> URL = Self.productionRootURL()
    ) -> Resolution {
        if let injected {
            return Resolution(url: injected, source: .injected)
        }
        if environmentOverrideAllowed || isRunningUnderXCTest,
           let override = environmentOverrideURL(from: environment)
        {
            return Resolution(url: override, source: .environmentOverride)
        }
        if isRunningUnderXCTest {
            return Resolution(url: xctestTemporaryRoot(), source: .xctestTemporary)
        }
        return Resolution(url: productionRoot(), source: .production)
    }

    /// `<Application Support>/RepoPrompt CE/Workspaces`, the live store.
    package static func productionRootURL(fileManager: FileManager = .default) -> URL {
        MCPFilesystemConstants.identity.applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(workspacesDirectoryName, isDirectory: true)
    }

    static let xctestContainerDirectoryName = "RepoPromptCE-XCTest"
    static let xctestRootNamePrefix = "Workspaces-"
    package static let staleXCTestRootAge: TimeInterval = 24 * 60 * 60

    /// One root per test process, chosen on first use and stable for the process lifetime.
    /// First use also sweeps stale roots left by earlier test processes (best effort).
    package static let xctestTemporaryRootURL: URL = {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(xctestContainerDirectoryName, isDirectory: true)
        removeStaleXCTestRoots(in: container)
        return container.appendingPathComponent(
            "\(xctestRootNamePrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
    }()

    /// Best-effort removal of per-process XCTest roots that are older than `maximumAge` and whose
    /// owning process is gone. Touches only `Workspaces-<pid>-<uuid>` directories directly inside a
    /// container named `RepoPromptCE-XCTest`; other entries (including other fixtures sharing that
    /// container), symlinks, live owners, and recent roots are left alone. Errors are ignored.
    /// Returns the roots it removed.
    @discardableResult
    package static func removeStaleXCTestRoots(
        in container: URL,
        now: Date = Date(),
        maximumAge: TimeInterval = staleXCTestRootAge,
        isProcessAlive: (Int32) -> Bool = Self.isProcessAlive,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard container.lastPathComponent == xctestContainerDirectoryName else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var removed: [URL] = []
        for entry in entries {
            guard let pid = xctestRootProcessID(fromDirectoryName: entry.lastPathComponent),
                  let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge,
                  !isProcessAlive(pid)
            else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil {
                removed.append(entry)
            }
        }
        return removed
    }

    /// The owning pid of a `Workspaces-<pid>-<uuid>` root name; `nil` for any other name.
    static func xctestRootProcessID(fromDirectoryName name: String) -> Int32? {
        guard name.hasPrefix(xctestRootNamePrefix) else { return nil }
        let rest = name.dropFirst(xctestRootNamePrefix.count)
        guard let separator = rest.firstIndex(of: "-"),
              let pid = Int32(rest[..<separator]), pid > 0,
              UUID(uuidString: String(rest[rest.index(after: separator)...])) != nil
        else { return nil }
        return pid
    }

    /// `kill(pid, 0)`: alive when it succeeds or the process exists but is not signalable.
    package static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    package static var isRunningUnderXCTest: Bool {
        NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
    }

    static var environmentOverrideAllowed: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private static func environmentOverrideURL(from environment: [String: String]) -> URL? {
        guard let raw = environment[environmentOverrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("/")
        else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }
}

/// The user-chosen global custom location for default-path workspaces (an explicit root that takes
/// precedence over `WorkspaceStorageRoot.defaultRootURL`).
///
/// The app persists it in `UserDefaults.standard`. Under XCTest it is a process-local value that
/// starts empty and is never read from or written to user defaults: the test host's defaults domain
/// (`com.apple.dt.xctest.tool`) persists across test processes, so a value left behind by an
/// interrupted test, or written by any other tool, would otherwise silently redirect every later
/// test process's workspace storage away from the per-process XCTest root.
package enum WorkspaceGlobalCustomStorageLocation {
    package static let defaultsKey = "GlobalCustomStorageURL"

    private final class ProcessLocalValue: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?

        var value: String? {
            get { lock.withLock { path } }
            set { lock.withLock { path = newValue } }
        }
    }

    private static let processLocal = ProcessLocalValue()

    package static func load() -> URL? {
        resolve(
            isRunningUnderXCTest: WorkspaceStorageRoot.isRunningUnderXCTest,
            processLocalPath: processLocal.value,
            persistedPath: UserDefaults.standard.string(forKey: defaultsKey)
        )
    }

    package static func store(_ url: URL?) {
        if WorkspaceStorageRoot.isRunningUnderXCTest {
            processLocal.value = url?.path
        } else if let url {
            UserDefaults.standard.set(url.path, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// Source selection, injectable for tests: the process-local value under XCTest, else the
    /// persisted value. The persisted value is never evaluated under XCTest.
    static func resolve(
        isRunningUnderXCTest: Bool,
        processLocalPath: String?,
        persistedPath: @autoclosure () -> String?
    ) -> URL? {
        let path = isRunningUnderXCTest ? processLocalPath : persistedPath()
        return path.map { URL(fileURLWithPath: $0) }
    }
}
