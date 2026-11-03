import Foundation
@testable import RepoPromptApp
@testable import RepoPromptUI
import XCTest

/// Workspace steering grant storage (assistant workspace steering spec, Step 1). Uses temporary
/// settings JSON and defaults suites; no real settings, Keychain, or app lifecycle. Two stores on
/// one file stand in for Dev and release builds running at the same time.
@MainActor
final class WorkspaceSteeringGrantStoreTests: XCTestCase {
    private let assistant = UUID()
    private let target = UUID()
    private let other = UUID()
    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    func testPreFeatureV5DocumentLoadsWithNoGrantsAndKeepsOtherSettings() throws {
        let old = try JSONDecoder().decode(
            GlobalScalarPreferences.self,
            from: Data(#"{"telemetry":{"enabled":false},"telegram":{"enabled":false}}"#.utf8)
        )
        XCTAssertNil(old.workspaceSteeringGrants)

        let fileURL = try makeSettingsFileURL()
        let preFeature = """
        {"schemaVersion":5,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-10-01T00:00:00Z",\
        "copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},\
        "scalarPreferences":{"ui":{"showTooltips":false},"telegram":{"enabled":true,"chatID":"7"}}}
        """
        try Data(preFeature.utf8).write(to: fileURL)

        let fixture = try makeFixture(fileURL: fileURL)
        XCTAssertNil(fixture.settings.persistenceBlockReason)
        XCTAssertEqual(fixture.store.grants, [])
        XCTAssertFalse(fixture.store.isGranted(source: assistant, target: target))

        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .added)
        let reloaded = reloadedSettings(fixture)
        XCTAssertNil(reloaded.persistenceBlockReason)
        XCTAssertFalse(reloaded.showTooltips(), "Other groups survive the grant write")
        XCTAssertTrue(reloaded.telegramNotificationsEnabled())
        XCTAssertEqual(reloaded.telegramChatID(), "7")
        XCTAssertEqual(reloaded.workspaceSteeringGrants().count, 1)
    }

    func testNonemptyGrantsStampFixedSchemaVersionThatOlderBuildsPreserve() throws {
        XCTAssertEqual(GlobalSettingsDocument.workspaceSteeringGrantsSchemaVersion, 6)
        let grant = WorkspaceSteeringGrant(sourceWorkspaceID: assistant, targetWorkspaceID: target, createdAt: Self.fixedNow)
        let withGrant = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(workspaceSteeringGrants: [grant]))
        XCTAssertEqual(withGrant.requiredSchemaVersion, GlobalSettingsDocument.workspaceSteeringGrantsSchemaVersion)
        let withoutGrant = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(workspaceSteeringGrants: []))
        XCTAssertEqual(withoutGrant.requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)

        let fixture = try makeFixture()
        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .added)
        XCTAssertEqual(try onDiskSchemaVersion(fixture.fileURL), 6)
        XCTAssertEqual(
            GlobalSettingsFileStore.preservationBlockReason(schemaVersion: 6, schemaLineage: GlobalSettingsDocument.schemaLineage, supportedVersion: 5),
            .unsupportedFutureSchema(onDiskVersion: 6, supportedVersion: 5),
            "A pre-grant (v5) build preserves the file instead of saving over the grants"
        )

        XCTAssertEqual(fixture.store.remove(source: assistant, target: target), .removed)
        XCTAssertEqual(
            try onDiskSchemaVersion(fixture.fileURL),
            GlobalSettingsDocument.baselineSchemaVersion,
            "With no grants left, older builds can use the file again"
        )
    }

    func testAddPersistsDirectedGrantAndRejectsDuplicateAndSelfGrants() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .added)
        XCTAssertTrue(fixture.store.isGranted(source: assistant, target: target))
        XCTAssertFalse(fixture.store.isGranted(source: target, target: assistant), "Grants are one-way")

        let saves = fixture.fileStore.saveCount
        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .alreadyGranted)
        XCTAssertEqual(fixture.store.add(source: other, target: other), .rejectedSelfGrant)
        XCTAssertEqual(fixture.store.remove(source: other, target: target), .notFound)
        XCTAssertEqual(fixture.fileStore.saveCount, saves, "Refused changes write nothing")
        XCTAssertFalse(fixture.store.isGranted(source: other, target: other))
        let expected = [WorkspaceSteeringGrant(sourceWorkspaceID: assistant, targetWorkspaceID: target, createdAt: Self.fixedNow)]
        XCTAssertEqual(fixture.store.grants, expected)

        let reloaded = reloadedStore(fixture)
        XCTAssertEqual(reloaded.grants, expected)
        XCTAssertTrue(reloaded.isGranted(source: assistant, target: target))

        XCTAssertEqual(fixture.store.add(source: target, target: assistant), .added, "The reverse pair is a separate grant")
        XCTAssertEqual(reloadedStore(fixture).grants.count, 2)
    }

    func testFailedSaveLeavesPriorGrantsInEffect() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .added)
        let prior = fixture.store.grants

        fixture.fileStore.failSaves = true
        XCTAssertEqual(fixture.store.add(source: other, target: target), .saveFailed)
        XCTAssertFalse(fixture.store.isGranted(source: other, target: target), "An unsaved grant is not kept")
        XCTAssertEqual(fixture.store.remove(source: assistant, target: target), .saveFailed)
        XCTAssertTrue(fixture.store.isGranted(source: assistant, target: target), "An unsaved removal is not kept")
        XCTAssertEqual(fixture.store.grants, prior)
        XCTAssertEqual(reloadedStore(fixture).grants, prior)

        fixture.fileStore.failSaves = false
        XCTAssertEqual(fixture.store.remove(source: assistant, target: target), .removed)
        XCTAssertEqual(reloadedStore(fixture).grants, [])
    }

    func testRemoveEndsIsGranted() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .added)
        XCTAssertEqual(fixture.store.add(source: assistant, target: other), .added)

        XCTAssertEqual(fixture.store.remove(source: assistant, target: target), .removed)
        XCTAssertFalse(fixture.store.isGranted(source: assistant, target: target))
        XCTAssertTrue(fixture.store.isGranted(source: assistant, target: other), "Only the removed pair ends")
        XCTAssertFalse(reloadedStore(fixture).isGranted(source: assistant, target: target))
        XCTAssertEqual(fixture.store.remove(source: assistant, target: target), .notFound)

        XCTAssertEqual(fixture.store.remove(source: assistant, target: other), .removed)
        let persisted = try GlobalSettingsFileStore(fileURL: fixture.fileURL).load()
        XCTAssertNil(persisted.scalarPreferences?.workspaceSteeringGrants, "An empty list is stored as absent")
    }

    func testSecondRunningInstanceNeitherHonorsNorResurrectsARevokedGrant() throws {
        let dev = try makeFixture()
        XCTAssertEqual(dev.store.add(source: assistant, target: target), .added)
        let release = reloadedStore(dev)
        XCTAssertEqual(release.grants.count, 1, "Release loaded the grant")

        XCTAssertEqual(dev.store.remove(source: assistant, target: target), .removed)
        XCTAssertFalse(release.isGranted(source: assistant, target: target), "Checks read the file, not the stale copy")

        release.settings.setShowTooltips(false)
        XCTAssertEqual(release.grants, [], "An unrelated save adopts the on-disk grants")
        let fresh = reloadedSettings(dev)
        XCTAssertFalse(fresh.showTooltips(), "The unrelated change was saved")
        XCTAssertEqual(fresh.workspaceSteeringGrants(), [], "The revoked grant was not written back")

        XCTAssertEqual(dev.store.add(source: assistant, target: other), .added)
        release.settings.setShowTooltips(true)
        XCTAssertTrue(reloadedStore(dev).isGranted(source: assistant, target: other), "Nor is a new grant dropped")
        XCTAssertEqual(
            release.remove(source: assistant, target: target),
            .notFound,
            "A remove from a stale view acts on the file"
        )
    }

    func testUnavailableSettingsLockWritesNothingAndReportsSaveFailed() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .added)
        let bytes = try Data(contentsOf: fixture.fileURL)
        let saves = fixture.fileStore.saveCount

        let lock = try holdSettingsLock(fixture.fileURL)
        XCTAssertEqual(fixture.store.add(source: other, target: target), .saveFailed, "No waiting for the lock")
        XCTAssertEqual(fixture.store.remove(source: assistant, target: target), .saveFailed)
        fixture.settings.setShowTooltips(false)
        XCTAssertEqual(fixture.fileStore.saveCount, saves, "Nothing reaches the file store without the lock")
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), bytes)
        XCTAssertEqual(fixture.settings.persistenceBlockReason, .saveFailed)
        XCTAssertTrue(fixture.store.isGranted(source: assistant, target: target))
        XCTAssertFalse(fixture.store.isGranted(source: other, target: target))

        releaseSettingsLock(lock)
        XCTAssertTrue(fixture.settings.retryBlockedPersistenceSave())
        XCTAssertNil(fixture.settings.persistenceBlockReason)
        XCTAssertFalse(reloadedSettings(fixture).showTooltips(), "The retried save writes the pending change")
    }

    func testUnreadableGrantsAreNeitherHonoredNorOverwrittenAndMissingFileMeansNone() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.store.add(source: assistant, target: target), .added)

        let malformedGrants = """
        {"schemaVersion":6,"schemaLineage":"repoprompt-ce.global-settings","updatedAt":"2026-11-01T00:00:00Z",\
        "copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},\
        "scalarPreferences":{"workspaceSteeringGrants":"oops"}}
        """
        for unreadable in [Data("not json".utf8), Data(malformedGrants.utf8)] {
            try unreadable.write(to: fixture.fileURL)
            XCTAssertFalse(fixture.store.isGranted(source: assistant, target: target), "Fails closed")
            XCTAssertEqual(fixture.store.add(source: other, target: target), .saveFailed)
            XCTAssertEqual(fixture.store.remove(source: assistant, target: target), .saveFailed)
            fixture.settings.setShowTooltips(false)
            XCTAssertEqual(
                try Data(contentsOf: fixture.fileURL),
                unreadable,
                "The stale in-memory grant is not written over an unreadable file"
            )
            XCTAssertEqual(fixture.settings.persistenceBlockReason, .saveFailed)
        }

        try FileManager.default.removeItem(at: fixture.fileURL)
        XCTAssertFalse(fixture.store.isGranted(source: assistant, target: target), "A missing file holds no grants")
        XCTAssertEqual(fixture.store.add(source: other, target: target), .added)
        XCTAssertNil(fixture.settings.persistenceBlockReason)
        XCTAssertEqual(
            reloadedStore(fixture).grants.map(\.sourceWorkspaceID),
            [other],
            "The stale in-memory grant is not resurrected into a new file"
        )
    }

    func testGrantSurvivesWorkspaceRenameAndDeletedWorkspaceShowsUnknown() throws {
        let fixture = try makeFixture()
        var source = WorkspaceModel(id: assistant, name: "Assistant", repoPaths: [])
        let destination = WorkspaceModel(id: target, name: "Product", repoPaths: [])
        XCTAssertEqual(fixture.store.add(source: source.id, target: destination.id), .added)
        XCTAssertEqual(fixture.store.rows(workspaces: [source, destination]).map(\.sourceName), ["Assistant"])

        source.name = "Overseer"
        let reloaded = reloadedStore(fixture)
        XCTAssertTrue(reloaded.isGranted(source: source.id, target: destination.id))
        let row = try XCTUnwrap(reloaded.rows(workspaces: [source, destination]).first)
        XCTAssertEqual(row.sourceName, "Overseer")
        XCTAssertEqual(row.targetName, "Product")

        let afterDeletion = try XCTUnwrap(reloaded.rows(workspaces: [source]).first)
        XCTAssertNil(afterDeletion.targetName, "A deleted workspace is shown as unknown")
        XCTAssertTrue(reloaded.isGranted(source: source.id, target: destination.id), "It stays until removed")
        XCTAssertEqual(reloaded.remove(source: source.id, target: destination.id), .removed)
    }

    func testSameNameWorkspacesAreDistinguishedAndDuplicatePairsShowOneRow() throws {
        let product = WorkspaceModel(id: target, name: "Product", repoPaths: [])
        let otherProduct = WorkspaceModel(id: other, name: "Product", repoPaths: [])
        let names = WorkspaceSteeringGrantStore.displayNames(for: [product, otherProduct])
        XCTAssertNotEqual(names[target], names[other])
        XCTAssertEqual(names[target], "Product (\(target.uuidString.prefix(8)))")

        let fixture = try makeFixture()
        let grant = WorkspaceSteeringGrant(sourceWorkspaceID: assistant, targetWorkspaceID: target, createdAt: Self.fixedNow)
        let plainStore = GlobalSettingsFileStore(fileURL: fixture.fileURL)
        var document = try plainStore.load()
        var scalars = document.scalarPreferences ?? GlobalScalarPreferences()
        scalars.workspaceSteeringGrants = [grant, grant]
        document.scalarPreferences = scalars
        try plainStore.save(document)

        let reloaded = reloadedStore(fixture)
        XCTAssertEqual(reloaded.rows(workspaces: [product, otherProduct]).count, 1)
        XCTAssertEqual(reloaded.remove(source: assistant, target: target), .removed)
        XCTAssertFalse(reloaded.isGranted(source: assistant, target: target), "Every stored copy is removed")
    }

    func testSettingsSearchFindsSteeringSection() {
        for query in ["steer", "grant", "assistant", "workspace steering"] {
            XCTAssertTrue(
                SettingsTab.manageWorkspaces.searchTags.contains { $0.lowercased().contains(query) },
                "Expected Manage Workspaces to match \(query)"
            )
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let fileURL: URL
        let defaults: UserDefaults
        let fileStore: SwitchableGrantSettingsFileStore
        let settings: GlobalSettingsStore
        let store: WorkspaceSteeringGrantStore
    }

    private func makeSettingsFileURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSteeringGrantStoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return fileURL
    }

    private func makeFixture(fileURL: URL? = nil) throws -> Fixture {
        let fileURL = try fileURL ?? makeSettingsFileURL()
        let defaults = try makeDefaults()
        let fileStore = SwitchableGrantSettingsFileStore(base: GlobalSettingsFileStore(fileURL: fileURL))
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        let store = WorkspaceSteeringGrantStore(settings: settings, now: { Self.fixedNow })
        return Fixture(fileURL: fileURL, defaults: defaults, fileStore: fileStore, settings: settings, store: store)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WorkspaceSteeringGrantStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    /// A separate store instance on the same file, as another build (or a relaunch) would load it.
    private func reloadedSettings(_ fixture: Fixture) -> GlobalSettingsStore {
        GlobalSettingsStore(
            defaults: (try? makeDefaults()) ?? fixture.defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL)
        )
    }

    private func reloadedStore(_ fixture: Fixture) -> WorkspaceSteeringGrantStore {
        WorkspaceSteeringGrantStore(settings: reloadedSettings(fixture), now: { Self.fixedNow })
    }

    /// Holds the settings lock through a separate open file description, as another process would.
    private func holdSettingsLock(_ fileURL: URL) throws -> Int32 {
        let descriptor = open(GlobalSettingsFileLock.lockFileURL(for: fileURL).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        addTeardownBlock { _ = close(descriptor) }
        return descriptor
    }

    private func releaseSettingsLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
    }

    private func onDiskSchemaVersion(_ fileURL: URL) throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        return object?["schemaVersion"] as? Int
    }
}

/// Real settings file store whose saves can be made to fail; counts attempted saves.
private final class SwitchableGrantSettingsFileStore: GlobalSettingsFileStoring {
    let base: GlobalSettingsFileStore
    var failSaves = false
    private(set) var saveCount = 0

    init(base: GlobalSettingsFileStore) {
        self.base = base
    }

    var fileURL: URL {
        base.fileURL
    }

    var blockReason: GlobalSettingsPersistenceBlockReason? {
        base.blockReason
    }

    func load() throws -> GlobalSettingsDocument {
        try base.load()
    }

    func loadOrCreateDefault() -> GlobalSettingsDocument {
        base.loadOrCreateDefault()
    }

    func save(_ document: GlobalSettingsDocument) throws {
        saveCount += 1
        if failSaves {
            throw CocoaError(.fileWriteNoPermission)
        }
        try base.save(document)
    }

    func performUserInitiatedRecovery(replacementDocument: GlobalSettingsDocument) -> Bool {
        base.performUserInitiatedRecovery(replacementDocument: replacementDocument)
    }

    func performUserInitiatedCompatibleImport() -> Bool {
        base.performUserInitiatedCompatibleImport()
    }
}
