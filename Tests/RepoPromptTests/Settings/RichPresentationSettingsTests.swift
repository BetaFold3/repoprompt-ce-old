import Foundation
@testable import RepoPromptApp
@testable import RepoPromptUI
import XCTest

/// Workspace rich presentation settings storage (rich presentation spec, Step 1 / A3). Uses
/// temporary settings JSON and defaults suites; no real settings or app lifecycle. Two stores on
/// one file stand in for two builds running at the same time.
@MainActor
final class RichPresentationSettingsTests: XCTestCase {
    private let workspace = UUID()
    private let otherWorkspace = UUID()
    private static let lineage = GlobalSettingsDocument.schemaLineage

    // MARK: - Defaults and decoding

    func testPreFeatureDocumentAndMissingFieldsMeanDisabledWithNoHosts() throws {
        let fileURL = try makeSettingsFileURL()
        let preFeature = """
        {"schemaVersion":6,"schemaLineage":"\(Self.lineage)","updatedAt":"2026-11-01T00:00:00Z",\
        "copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},\
        "scalarPreferences":{"ui":{"showTooltips":false}}}
        """
        try Data(preFeature.utf8).write(to: fileURL)

        let fixture = try makeFixture(fileURL: fileURL)
        XCTAssertNil(fixture.settings.persistenceBlockReason)
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace), .disabled)
        XCTAssertFalse(fixture.settings.richPresentationSettings(for: workspace).enabled)
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace).approvedImageHosts, [])

        let emptyEntry = try JSONDecoder().decode(WorkspaceRichPresentationSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(emptyEntry, .disabled, "Absent entry fields mean false/empty")
        XCTAssertFalse(emptyEntry.storedEntryWasInvalid)
    }

    func testGrantingEntryStampsFixedSchemaV7ThatOlderBuildsPreserveAndDisablingLowersIt() throws {
        XCTAssertEqual(GlobalSettingsDocument.workspaceRichPresentationSchemaVersion, 7)
        let granting = GlobalSettingsDocument(
            richPresentationSettings: [workspace: WorkspaceRichPresentationSettings(enabled: true)]
        )
        XCTAssertEqual(granting.requiredSchemaVersion, GlobalSettingsDocument.workspaceRichPresentationSchemaVersion)
        let hostsOnly = GlobalSettingsDocument(
            richPresentationSettings: [workspace: WorkspaceRichPresentationSettings(approvedImageHosts: ["images.example.com"])]
        )
        XCTAssertEqual(hostsOnly.requiredSchemaVersion, GlobalSettingsDocument.workspaceRichPresentationSchemaVersion)
        let nonGranting = GlobalSettingsDocument(richPresentationSettings: [workspace: .disabled])
        XCTAssertNil(nonGranting.richPresentationSettingsByWorkspaceID, "Non-granting entries are not stored")
        XCTAssertEqual(nonGranting.requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)

        let fixture = try makeFixture()
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: workspace))
        XCTAssertEqual(try onDiskSchemaVersion(fixture.fileURL), 7)
        XCTAssertEqual(
            GlobalSettingsFileStore.preservationBlockReason(schemaVersion: 7, schemaLineage: Self.lineage, supportedVersion: 6),
            .unsupportedFutureSchema(onDiskVersion: 7, supportedVersion: 6),
            "A pre-feature (v6) build preserves the file instead of saving over the permission"
        )

        XCTAssertTrue(fixture.settings.setRichPresentationSettings(.disabled, for: workspace))
        XCTAssertEqual(try onDiskSchemaVersion(fixture.fileURL), GlobalSettingsDocument.baselineSchemaVersion)
        let persisted = try GlobalSettingsFileStore(fileURL: fixture.fileURL).load()
        XCTAssertNil(persisted.richPresentationSettingsByWorkspaceID, "A disabled, empty entry is stored as absent")
    }

    // MARK: - Committed writes

    func testSetPersistsNormalizedHostsPerWorkspaceOnly() throws {
        let fixture = try makeFixture()
        let requested = WorkspaceRichPresentationSettings(
            enabled: true,
            approvedImageHosts: ["static.example.org", "images.example.com", "images.example.com"]
        )
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(requested, for: workspace))

        let expected = WorkspaceRichPresentationSettings(
            enabled: true,
            approvedImageHosts: ["images.example.com", "static.example.org"]
        )
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace), expected)
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace).approvedImageHosts, expected.approvedImageHosts)
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: otherWorkspace), .disabled, "Workspaces are isolated")

        let reloaded = reloadedSettings(fixture)
        XCTAssertEqual(reloaded.richPresentationSettings(for: workspace), expected)
        XCTAssertEqual(reloaded.richPresentationSettings(for: otherWorkspace), .disabled)

        let saves = fixture.fileStore.saveCount
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(expected, for: workspace))
        XCTAssertEqual(fixture.fileStore.saveCount, saves, "An unchanged entry writes nothing")
    }

    func testInvalidHostsAreRejectedWithoutWritingOrRepair() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: workspace))
        let saves = fixture.fileStore.saveCount
        for host in [
            "*.example.com", "Images.example.com", " images.example.com", "localhost", "photos.local",
            "1.2.3.4", "[::1]", "example", "images.example.com:443", "https://images.example.com", ""
        ] {
            XCTAssertFalse(
                fixture.settings.setRichPresentationSettings(
                    .init(enabled: true, approvedImageHosts: [host]),
                    for: workspace
                ),
                "Expected \(host) to be rejected"
            )
        }
        XCTAssertEqual(fixture.fileStore.saveCount, saves, "Rejected entries write nothing")
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace).approvedImageHosts, [])
        XCTAssertNil(fixture.settings.persistenceBlockReason)
    }

    func testFailedSaveNeverActivatesPermissionAndRetrySucceeds() throws {
        let fixture = try makeFixture()
        let prior = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(prior, for: workspace))

        fixture.fileStore.failSaves = true
        let widened = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com", "cdn.example.net"])
        XCTAssertFalse(fixture.settings.setRichPresentationSettings(widened, for: workspace))
        XCTAssertFalse(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: otherWorkspace))
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace), prior, "An unsaved host is not kept")
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: otherWorkspace), .disabled, "An unsaved enable is not kept")
        XCTAssertEqual(reloadedSettings(fixture).richPresentationSettings(for: workspace), prior)

        fixture.fileStore.failSaves = false
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(widened, for: workspace))
        XCTAssertNil(fixture.settings.persistenceBlockReason)
        XCTAssertEqual(reloadedSettings(fixture).richPresentationSettings(for: workspace), widened)
    }

    func testUnavailableSettingsLockWritesNothingAndKeepsCommittedValue() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: otherWorkspace))
        let bytes = try Data(contentsOf: fixture.fileURL)
        let saves = fixture.fileStore.saveCount

        let lock = try holdSettingsLock(fixture.fileURL)
        XCTAssertFalse(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: workspace))
        XCTAssertEqual(fixture.fileStore.saveCount, saves, "Nothing reaches the file store without the lock")
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), bytes)
        XCTAssertEqual(fixture.settings.persistenceBlockReason, .saveFailed)
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace), .disabled)

        releaseSettingsLock(lock)
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: workspace))
        XCTAssertTrue(reloadedSettings(fixture).richPresentationSettings(for: workspace).enabled)
    }

    // MARK: - Cross-instance and fail-closed storage

    func testUnrelatedSaveFromStaleInstanceNeitherResurrectsNorDropsPermissions() throws {
        let dev = try makeFixture()
        let approved = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        XCTAssertTrue(dev.settings.setRichPresentationSettings(approved, for: workspace))
        let release = reloadedSettings(dev)
        XCTAssertEqual(release.richPresentationSettings(for: workspace), approved, "Release loaded the permission")

        XCTAssertTrue(dev.settings.setRichPresentationSettings(.disabled, for: workspace))
        release.setShowTooltips(false)
        XCTAssertEqual(release.richPresentationSettings(for: workspace), .disabled, "An unrelated save adopts the on-disk map")
        let fresh = reloadedSettings(dev)
        XCTAssertFalse(fresh.showTooltips(), "The unrelated change was saved")
        XCTAssertEqual(fresh.richPresentationSettings(for: workspace), .disabled, "The removed permission was not written back")

        XCTAssertTrue(dev.settings.setRichPresentationSettings(approved, for: otherWorkspace))
        release.setShowTooltips(true)
        XCTAssertEqual(reloadedSettings(dev).richPresentationSettings(for: otherWorkspace), approved, "Nor is a new one dropped")

        XCTAssertTrue(release.setRichPresentationSettings(.init(enabled: true), for: workspace))
        XCTAssertEqual(
            reloadedSettings(dev).richPresentationSettings(for: otherWorkspace),
            approved,
            "A stale instance's set replaces only its own workspace entry"
        )
    }

    func testStaleInstanceSteeringGrantWriteNeitherResurrectsNorDropsRichPermissions() throws {
        let dev = try makeFixture()
        let approved = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        XCTAssertTrue(dev.settings.setRichPresentationSettings(approved, for: workspace))
        let release = reloadedSettings(dev)
        XCTAssertEqual(release.richPresentationSettings(for: workspace), approved, "Release loaded the permission")

        XCTAssertTrue(dev.settings.setRichPresentationSettings(.disabled, for: workspace))
        let widened = WorkspaceRichPresentationSettings(
            enabled: true,
            approvedImageHosts: ["cdn.example.net", "images.example.com"]
        )
        XCTAssertTrue(dev.settings.setRichPresentationSettings(widened, for: otherWorkspace))

        let releaseGrants = WorkspaceSteeringGrantStore(settings: release, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        XCTAssertEqual(releaseGrants.add(source: workspace, target: otherWorkspace), .added)
        XCTAssertEqual(release.richPresentationSettings(for: workspace), .disabled, "The grant write adopts the on-disk map")

        let fresh = reloadedSettings(dev)
        XCTAssertEqual(fresh.workspaceSteeringGrants().count, 1, "The grant was saved")
        XCTAssertEqual(fresh.richPresentationSettings(for: workspace), .disabled, "The removed permission was not written back")
        XCTAssertEqual(fresh.richPresentationSettings(for: otherWorkspace), widened, "Nor were the new hosts dropped")
    }

    func testMalformedStoredEntriesGrantNothingWhileValidEntriesLoad() throws {
        let fileURL = try makeSettingsFileURL()
        let valid = UUID()
        let wrongType = UUID()
        let notObject = UUID()
        let badHost = UUID()
        let document = """
        {"schemaVersion":7,"schemaLineage":"\(Self.lineage)","updatedAt":"2026-11-05T00:00:00Z",\
        "copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{},\
        "richPresentationSettingsByWorkspaceID":{\
        "\(valid.uuidString)":{"enabled":true,"approved_image_hosts":["images.example.com"]},\
        "\(wrongType.uuidString)":{"enabled":"yes"},\
        "\(notObject.uuidString)":5,\
        "\(badHost.uuidString)":{"enabled":true,"approved_image_hosts":["images.example.com","*.example.com"]}}}
        """
        try Data(document.utf8).write(to: fileURL)

        let fixture = try makeFixture(fileURL: fileURL)
        XCTAssertNil(fixture.settings.persistenceBlockReason, "A malformed entry does not block the document")
        XCTAssertEqual(
            fixture.settings.richPresentationSettings(for: valid),
            WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        )
        for workspaceID in [wrongType, notObject, badHost] {
            let entry = fixture.settings.richPresentationSettings(for: workspaceID)
            XCTAssertFalse(entry.enabled, "enabled is never salvaged from a malformed entry")
            XCTAssertEqual(entry.approvedImageHosts, [])
            XCTAssertTrue(entry.storedEntryWasInvalid)
        }
    }

    func testUnreadableMapAndPreservedFutureFileRefuseWritesAndGrantNothing() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: workspace))

        let malformedMap = """
        {"schemaVersion":7,"schemaLineage":"\(Self.lineage)","updatedAt":"2026-11-05T00:00:00Z",\
        "copySettingsByWorkspaceID":{},"chatSettingsByWorkspaceID":{},"globalDefaults":{},"scalarPreferences":{},\
        "richPresentationSettingsByWorkspaceID":"oops"}
        """
        for unreadable in [Data("not json".utf8), Data(malformedMap.utf8)] {
            try unreadable.write(to: fixture.fileURL)
            XCTAssertFalse(fixture.settings.setRichPresentationSettings(.init(enabled: true), for: otherWorkspace))
            fixture.settings.setShowTooltips(false)
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), unreadable, "Nothing is written over an unreadable file")
            XCTAssertEqual(fixture.settings.richPresentationSettings(for: otherWorkspace), .disabled)
        }

        let future = """
        {"schemaVersion":999,"schemaLineage":"\(Self.lineage)","updatedAt":"2026-11-05T00:00:00Z",\
        "richPresentationSettingsByWorkspaceID":{"\(workspace.uuidString)":{"enabled":true}}}
        """
        try Data(future.utf8).write(to: fixture.fileURL)
        let futureLoaded = reloadedSettings(fixture)
        XCTAssertNotNil(futureLoaded.persistenceBlockReason)
        XCTAssertEqual(futureLoaded.richPresentationSettings(for: workspace), .disabled, "In-memory defaults grant nothing")
        XCTAssertFalse(futureLoaded.setRichPresentationSettings(.init(enabled: true), for: otherWorkspace))
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), Data(future.utf8), "The future document is preserved")
    }

    // MARK: - Run admission reads the file (review R1)

    func testAdmissionReadSeesAnotherInstancesCommittedChangeAndFailsClosedOnUnreadableFiles() throws {
        let dev = try makeFixture()
        XCTAssertEqual(dev.settings.persistedRichPresentationSettings(for: workspace), .disabled, "A missing file grants nothing")

        let approved = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        XCTAssertTrue(dev.settings.setRichPresentationSettings(approved, for: workspace))
        let release = reloadedSettings(dev)
        XCTAssertEqual(release.persistedRichPresentationSettings(for: workspace), approved)
        XCTAssertEqual(release.persistedRichPresentationSettings(for: otherWorkspace), .disabled, "A missing entry grants nothing")

        XCTAssertTrue(dev.settings.setRichPresentationSettings(.disabled, for: workspace))
        XCTAssertEqual(release.richPresentationSettings(for: workspace), approved, "The display cache is still stale")
        XCTAssertEqual(
            release.persistedRichPresentationSettings(for: workspace),
            .disabled,
            "Admission sees the disable another instance committed"
        )
        XCTAssertEqual(release.richPresentationSettings(for: workspace), approved, "The admission read changes no memory")

        XCTAssertTrue(dev.settings.setRichPresentationSettings(approved, for: workspace))
        try Data("not json".utf8).write(to: dev.fileURL)
        XCTAssertNil(release.persistedRichPresentationSettings(for: workspace), "An unreadable file gives no authority")

        let future = """
        {"schemaVersion":999,"schemaLineage":"\(Self.lineage)","updatedAt":"2026-11-05T00:00:00Z",\
        "richPresentationSettingsByWorkspaceID":{"\(workspace.uuidString)":{"enabled":true}}}
        """
        try Data(future.utf8).write(to: dev.fileURL)
        XCTAssertNil(release.persistedRichPresentationSettings(for: workspace), "A future schema gives no authority")
        XCTAssertNil(dev.settings.persistedRichPresentationSettings(for: workspace))
    }

    // MARK: - Compare-and-set editor saves (review R3)

    func testCompareAndSetSaveRefusesAStaleBaseWithoutWriting() throws {
        let dev = try makeFixture()
        let original = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        XCTAssertTrue(dev.settings.setRichPresentationSettings(original, for: workspace))
        let release = reloadedSettings(dev)

        XCTAssertTrue(dev.settings.setRichPresentationSettings(.disabled, for: workspace))
        let bytes = try Data(contentsOf: dev.fileURL)
        let staleEdit = WorkspaceRichPresentationSettings(
            enabled: true,
            approvedImageHosts: ["cdn.example.net", "images.example.com"]
        )
        XCTAssertEqual(release.saveRichPresentationSettings(staleEdit, for: workspace, replacing: original), .conflict)
        XCTAssertEqual(try Data(contentsOf: dev.fileURL), bytes, "A conflicting save writes nothing")
        XCTAssertEqual(release.richPresentationSettings(for: workspace), .disabled, "The conflict adopts the newer entry")
        XCTAssertEqual(reloadedSettings(dev).richPresentationSettings(for: workspace), .disabled)

        XCTAssertEqual(release.saveRichPresentationSettings(staleEdit, for: workspace, replacing: .disabled), .saved)
        XCTAssertEqual(reloadedSettings(dev).richPresentationSettings(for: workspace), staleEdit, "A matching base saves")
        XCTAssertEqual(dev.settings.saveRichPresentationSettings(original, for: workspace, replacing: nil), .saved)
        XCTAssertEqual(reloadedSettings(dev).richPresentationSettings(for: workspace), original, "No base keeps set semantics")
    }

    func testCleanDraftFollowsCommittedChangesWhileADirtyDraftKeepsItsEditAndReportsTheConflict() {
        let first = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        let second = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["cdn.example.net"])

        var clean = RichPresentationSettingsDraft(committed: first)
        XCTAssertFalse(clean.isDirty)
        clean.reconcile(withCommitted: second)
        XCTAssertEqual(clean, RichPresentationSettingsDraft(committed: second), "A clean draft follows the committed entry")
        XCTAssertFalse(clean.hasConflict(with: second))

        var dirty = RichPresentationSettingsDraft(committed: first)
        dirty.enabled = false
        XCTAssertTrue(dirty.isDirty)
        XCTAssertFalse(dirty.hasConflict(with: first))
        dirty.reconcile(withCommitted: second)
        XCTAssertEqual(dirty.base, first, "A dirty draft keeps the base its edit started from")
        XCTAssertFalse(dirty.enabled, "and keeps the owner's edit")
        XCTAssertTrue(dirty.hasConflict(with: second))
        XCTAssertEqual(dirty.candidate, WorkspaceRichPresentationSettings(enabled: false, approvedImageHosts: ["images.example.com"]))
    }

    func testUndoingAnEditAfterAnExternalChangeRebasesOntoTheCurrentCommittedEntry() {
        // Review A R4: enabled with a host; the owner toggles off, another view removes the host.
        let original = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        let hostRemoved = WorkspaceRichPresentationSettings(enabled: true)
        var draft = RichPresentationSettingsDraft(committed: original)
        draft.enabled = false
        draft.reconcile(withCommitted: hostRemoved)
        XCTAssertEqual(draft.base, original, "The dirty edit is kept")
        XCTAssertTrue(draft.hasConflict(with: hostRemoved))

        // Undoing the edit makes the draft clean against its old base; it then adopts the current entry.
        draft.enabled = true
        XCTAssertFalse(draft.isDirty)
        draft.reconcile(withCommitted: hostRemoved)
        XCTAssertEqual(draft, RichPresentationSettingsDraft(committed: hostRemoved))
        XCTAssertEqual(draft.approvedImageHosts, [], "The removed host no longer shows as approved")
        XCTAssertFalse(draft.hasConflict(with: hostRemoved))
    }

    func testADirtyDraftEqualToTheNewCommittedEntryRebasesWithoutAConflict() {
        // Review B N4: the same change was saved elsewhere.
        let original = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        let same = WorkspaceRichPresentationSettings(enabled: false, approvedImageHosts: ["images.example.com"])
        var draft = RichPresentationSettingsDraft(committed: original)
        draft.enabled = false
        XCTAssertEqual(draft.candidate, same)
        draft.reconcile(withCommitted: same)
        XCTAssertEqual(draft, RichPresentationSettingsDraft(committed: same))
        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.hasConflict(with: same))

        // Reconciling against the committed entry it already started from changes nothing.
        var edited = RichPresentationSettingsDraft(committed: original)
        edited.approvedImageHosts = []
        edited.reconcile(withCommitted: original)
        XCTAssertEqual(edited.base, original)
        XCTAssertEqual(edited.approvedImageHosts, [], "An edit against the current entry is kept")
    }

    func testDisplayRefreshAdoptsAnotherInstancesSavedMapWithoutWriting() throws {
        // Review B N1: the section's onAppear refresh.
        let dev = try makeFixture()
        let release = reloadedSettings(dev)
        XCTAssertEqual(release.richPresentationSettings(for: workspace), .disabled)

        let approved = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        XCTAssertTrue(dev.settings.setRichPresentationSettings(approved, for: workspace))
        let bytes = try Data(contentsOf: dev.fileURL)
        let modified = try dev.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertTrue(release.refreshRichPresentationSettingsFromDisk())
        XCTAssertEqual(release.richPresentationSettings(for: workspace), approved, "The display shows what runs admit")
        XCTAssertEqual(try Data(contentsOf: dev.fileURL), bytes, "The refresh writes nothing")
        XCTAssertEqual(
            try dev.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            modified
        )

        let unreadable = Data("not json".utf8)
        try unreadable.write(to: dev.fileURL)
        XCTAssertFalse(release.refreshRichPresentationSettingsFromDisk())
        XCTAssertEqual(release.richPresentationSettings(for: workspace), approved, "Memory is left alone")
        XCTAssertEqual(try Data(contentsOf: dev.fileURL), unreadable, "Nothing is written over an unreadable file")
    }

    // MARK: - Document projections

    func testDocumentProjectionsRetainRichPresentationSettings() throws {
        let entry = WorkspaceRichPresentationSettings(enabled: true, approvedImageHosts: ["images.example.com"])
        let document = GlobalSettingsDocument(richPresentationSettings: [workspace: entry])

        let replaced = document.replacing(
            copySettings: [:],
            chatSettings: [:],
            agentModelsSettings: [:],
            globalDefaults: document.globalDefaults
        )
        XCTAssertEqual(replaced.richPresentationSettings, [workspace: entry], "Replacement keeps the map by default")

        let decoded = try JSONDecoder().decode(GlobalSettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.richPresentationSettings, [workspace: entry])
        let entryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        XCTAssertEqual(Set(entryObject.keys), ["enabled", "approved_image_hosts"], "Stored keys match the spec")

        let fixture = try makeFixture()
        XCTAssertTrue(fixture.settings.setRichPresentationSettings(entry, for: workspace))
        XCTAssertTrue(fixture.settings.reloadFromDisk())
        XCTAssertEqual(fixture.settings.richPresentationSettings(for: workspace), entry, "reloadFromDisk installs the map")
        fixture.settings.setShowTooltips(false)
        XCTAssertEqual(reloadedSettings(fixture).richPresentationSettings(for: workspace), entry, "Unrelated saves keep it")
    }

    // MARK: - Fixture

    private struct Fixture {
        let fileURL: URL
        let defaults: UserDefaults
        let fileStore: SwitchableRichPresentationSettingsFileStore
        let settings: GlobalSettingsStore
    }

    private func makeSettingsFileURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichPresentationSettingsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return fileURL
    }

    private func makeFixture(fileURL: URL? = nil) throws -> Fixture {
        let fileURL = try fileURL ?? makeSettingsFileURL()
        let defaults = try makeDefaults()
        let fileStore = SwitchableRichPresentationSettingsFileStore(base: GlobalSettingsFileStore(fileURL: fileURL))
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        return Fixture(fileURL: fileURL, defaults: defaults, fileStore: fileStore, settings: settings)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "RichPresentationSettingsTests.\(UUID().uuidString)"
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
private final class SwitchableRichPresentationSettingsFileStore: GlobalSettingsFileStoring {
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
