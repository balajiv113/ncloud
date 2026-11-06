import Flutter
import UIKit
import XCTest
import Photos
import BackgroundTasks
@testable import Runner

class RunnerTests: XCTestCase {

  func testSceneLifecycleConfiguration() {
    let bundle = Bundle.main
    let manifest = bundle.object(forInfoDictionaryKey: "UIApplicationSceneManifest")
      as? [String: Any]
    XCTAssertEqual(manifest?["UIApplicationSupportsMultipleScenes"] as? Bool, false)
    let configurations = manifest?["UISceneConfigurations"] as? [String: Any]
    let scenes = configurations?["UIWindowSceneSessionRoleApplication"]
      as? [[String: Any]]
    XCTAssertEqual(scenes?.count, 1)
    let name = scenes?.first?["UISceneDelegateClassName"] as? String
    XCTAssertNotNil(name.flatMap(NSClassFromString))
    XCTAssertNil(bundle.object(forInfoDictionaryKey: "UIMainStoryboardFile"))
    XCTAssertNil(scenes?.first?["UISceneStoryboardFile"])
  }

  func testSceneOwnsFlutterWindow() {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    XCTAssertTrue(scenes.contains { scene in
      scene.windows.contains { $0.rootViewController is FlutterViewController }
    })
  }

  func testBackgroundConfiguration() {
    let bundle = Bundle.main
    XCTAssertEqual(bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
      as? [String], [AlbumBackupScheduling.identifier])
    XCTAssertTrue((bundle.object(forInfoDictionaryKey: "UIBackgroundModes")
      as? [String] ?? []).contains("processing"))
    XCTAssertFalse((bundle.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription")
      as? String ?? "").isEmpty)
    let app = UIApplication.shared.delegate as? AppDelegate
    XCTAssertNotNil(app?.folders)
    XCTAssertTrue(app?.flutterEngine.hasPlugin(AppDelegate.FolderSyncBridge.pluginKey) ?? false)
  }

  func testPermissionRequiresFullAccessAndListNeverPrompts() throws {
    let source = FakeAlbumSource()
    let service = AlbumBackupService(source: source)
    for status in [PHAuthorizationStatus.limited, .denied, .restricted, .notDetermined] {
      source.authorization = status
      assertCode("photos_permission") { _ = try service.list(token: source.token, path: []) }
    }
    XCTAssertEqual(source.authorizationRequests, 0)
    source.authorization = .limited
    let requested = expectation(description: "explicit authorization")
    service.requestAlbums { outcome in
      if case .failure(let error) = outcome {
        XCTAssertEqual((error as? AlbumBackupError)?.code, "photos_permission")
      } else { XCTFail("Limited access must not claim to back up whole albums") }
      requested.fulfill()
    }
    wait(for: [requested], timeout: 1)
    XCTAssertEqual(source.authorizationRequests, 1)
  }

  func testAlbumTokensNamesAndIdentity() throws {
    let source = FakeAlbumSource()
    source.availableAlbums = [
      BackupAlbum(identifier: "album-1", title: "../A/\u{0}B"),
      BackupAlbum(identifier: "album-2", title: "../A/\u{0}B"),
      BackupAlbum(identifier: "album-3", title: String(repeating: "📷", count: 100)),
    ]
    let albums = try AlbumBackupService(source: source).authorizedAlbums()
    XCTAssertEqual(albums.count, 3)
    XCTAssertEqual(albums[0]["identity"] as? String, "photos:album-1")
    XCTAssertNotEqual(albums[0]["token"] as? String, albums[1]["token"] as? String)
    XCTAssertNotEqual(albums[0]["name"] as? String, albums[1]["name"] as? String)
    for album in albums {
      let name = try XCTUnwrap(album["name"] as? String)
      XCTAssertFalse(name.contains("/"))
      XCTAssertFalse(name.contains("\u{0}"))
      XCTAssertLessThanOrEqual(name.utf8.count, 180)
      XCTAssertEqual(album["kind"] as? String, "photoAlbum")
    }
    XCTAssertEqual(AlbumBackupService.safeName(".."), "Album")
    XCTAssertEqual(AlbumBackupService.safeName("."), "Album")
  }

  func testMissingAlbumAndRootOnlyListing() {
    let source = FakeAlbumSource()
    let service = AlbumBackupService(source: source)
    assertCode("photos_album") { _ = try service.list(token: source.token, path: ["child"]) }
    source.members = nil
    assertCode("photos_album") { _ = try service.list(token: source.token, path: []) }
    assertCode("photos_album") { _ = try service.list(token: "photos:invalid", path: []) }
  }

  func testOriginalsAndLivePhotoHaveStableDistinctNames() throws {
    let source = FakeAlbumSource()
    let original = source.still
    let paired = BackupResource(type: PHAssetResourceType.pairedVideo.rawValue,
                                filename: "IMG_0001.MOV", uti: "com.apple.quicktime-movie")
    let edited = BackupResource(type: PHAssetResourceType.fullSizePhoto.rawValue,
                                filename: "IMG_0001.JPG", uti: "public.jpeg")
    source.members = [
      source.asset("first", resources: [original, paired, edited]),
      source.asset("second", resources: [original]),
    ]
    let service = AlbumBackupService(source: source)
    let entries = try service.list(token: source.token, path: [])
    XCTAssertEqual(entries.count, 3)
    let names = entries.compactMap { $0["name"] as? String }
    XCTAssertEqual(Set(names).count, 3)
    XCTAssertEqual(names.filter { $0.hasSuffix(".HEIC") }.count, 2)
    XCTAssertEqual(names.filter { $0.hasSuffix(".MOV") }.count, 1)
    for entry in entries {
      XCTAssertEqual(entry["size"] as? Int64, -1)
      XCTAssertEqual(entry["directory"] as? Bool, false)
      XCTAssertGreaterThan(entry["modified"] as? Int64 ?? 0, 0)
      XCTAssertFalse((entry["revision"] as? String ?? "").isEmpty)
      XCTAssertFalse((entry["contentType"] as? String ?? "").isEmpty)
    }
    source.members?.reverse()
    XCTAssertEqual(Set(try service.list(token: source.token, path: [])
      .compactMap { $0["name"] as? String }), Set(names))
  }

  func testRevisionChangesWithoutSwitchingResourceName() throws {
    let source = FakeAlbumSource()
    let service = AlbumBackupService(source: source)
    let before = try XCTUnwrap(service.list(token: source.token, path: []).first)
    source.members = [source.asset("asset-1", modified: Date(timeIntervalSince1970: 200))]
    let after = try XCTUnwrap(service.list(token: source.token, path: []).first)
    XCTAssertEqual(before["name"] as? String, after["name"] as? String)
    XCTAssertNotEqual(before["revision"] as? String, after["revision"] as? String)
  }

  func testResourceSelectionIncludesUneditedRawAndVideoButNotAdjustments() {
    let source = FakeAlbumSource()
    let types: [PHAssetResourceType] = [.photo, .alternatePhoto, .video, .pairedVideo,
      .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo, .adjustmentData,
      .adjustmentBasePhoto, .audio]
    let asset = source.asset("raw-and-live", resources: types.map {
      BackupResource(type: $0.rawValue, filename: "original-\($0.rawValue).HEIC", uti: "public.heic")
    })
    XCTAssertEqual(Set(AlbumBackupService.originals(asset).map(\.type)),
      Set([PHAssetResourceType.photo.rawValue, PHAssetResourceType.alternatePhoto.rawValue,
           PHAssetResourceType.video.rawValue, PHAssetResourceType.pairedVideo.rawValue]))
  }

  func testAmbiguousResourceNamesFailInsteadOfSwitchingReceipts() {
    let source = FakeAlbumSource()
    source.members = [source.asset("ambiguous", resources: [source.still, source.still])]
    assertCode("photos_changed") {
      _ = try AlbumBackupService(source: source).list(token: source.token, path: [])
    }
  }

  func testExportPreservesOriginalBytesAndRevalidatesMembership() throws {
    try withTestDirectory { directory in
      let source = FakeAlbumSource()
      let service = AlbumBackupService(source: source)
      let entry = try XCTUnwrap(service.list(token: source.token, path: []).first)
      let name = try XCTUnwrap(entry["name"] as? String)
      let version = try XCTUnwrap(entry["revision"] as? String)
      let destination = directory.appendingPathComponent("original.part")
      XCTAssertEqual(try service.export(token: source.token, path: [name],
        version: version, destination: destination), destination.path)
      XCTAssertEqual(try Data(contentsOf: destination), source.bytes)
      XCTAssertEqual(source.writes, 1)
      XCTAssertEqual(source.authorizationRequests, 0)
      source.afterWrite = { source.members = [] }
      let changed = directory.appendingPathComponent("changed.part")
      assertCode("photos_changed") {
        _ = try service.export(token: source.token, path: [name], version: version, destination: changed)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: changed.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testExportsOnlyFetchTargetAssetWithoutRepeatingAlbumInventory() throws {
    try withTestDirectory { directory in
      let source = FakeAlbumSource()
      source.members = (0..<200).map { source.asset("asset-\($0)") }
      let service = AlbumBackupService(source: source)
      let entries = try service.list(token: source.token, path: [])
      XCTAssertEqual(source.inventoryRequests, 1)
      for (index, entry) in entries.prefix(3).enumerated() {
        _ = try service.export(token: source.token, path: [entry["name"] as! String],
          version: entry["revision"] as! String,
          destination: directory.appendingPathComponent("\(index).part"))
      }
      XCTAssertEqual(source.inventoryRequests, 1)
      XCTAssertEqual(source.targetedRequests, [
        "asset-0", "asset-0", "asset-1", "asset-1", "asset-2", "asset-2",
      ])
      XCTAssertEqual(source.writes, 3)
    }
  }

  func testTargetedValidationRejectsChangedResourcesBeforeAndAfterExport() throws {
    try withTestDirectory { directory in
      for duringWrite in [false, true] {
        let source = FakeAlbumSource()
        let service = AlbumBackupService(source: source)
        let entry = try XCTUnwrap(service.list(token: source.token, path: []).first)
        let mutate = {
          source.members = [source.asset("asset-1", resources: [
            source.still,
            BackupResource(type: PHAssetResourceType.adjustmentData.rawValue,
                           filename: "new-adjustment.plist", uti: "com.apple.property-list"),
          ])]
        }
        if duringWrite { source.afterWrite = mutate } else { mutate() }
        let destination = directory.appendingPathComponent(UUID().uuidString + ".part")
        assertCode("photos_changed") {
          _ = try service.export(token: source.token, path: [entry["name"] as! String],
            version: entry["revision"] as! String, destination: destination)
        }
        XCTAssertEqual(source.inventoryRequests, 1)
        XCTAssertEqual(source.targetedRequests.count, duringWrite ? 2 : 1)
        XCTAssertEqual(source.writes, duringWrite ? 1 : 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      }
    }
  }

  func testExportNeedsListSnapshotAndFailedRelistInvalidatesIt() throws {
    try withTestDirectory { directory in
      let source = FakeAlbumSource()
      let service = AlbumBackupService(source: source)
      let name = AlbumBackupService.filename(source.asset("asset-1"), source.still)
      let version = AlbumBackupService.revision(source.asset("asset-1"), source.still)
      let destination = directory.appendingPathComponent("unlisted.part")
      assertCode("photos_changed") {
        _ = try service.export(token: source.token, path: [name],
          version: version, destination: destination)
      }
      _ = try service.list(token: source.token, path: [])
      source.members = nil
      assertCode("photos_album") { _ = try service.list(token: source.token, path: []) }
      source.members = [source.asset("asset-1")]
      assertCode("photos_changed") {
        _ = try service.export(token: source.token, path: [name],
          version: version, destination: destination)
      }
      XCTAssertEqual(source.writes, 0)
      XCTAssertTrue(source.targetedRequests.isEmpty)
    }
  }

  func testExportRejectsStaleRevisionAndRemovedAlbumBeforeWriting() throws {
    try withTestDirectory { directory in
      let source = FakeAlbumSource()
      let service = AlbumBackupService(source: source)
      let entry = try XCTUnwrap(service.list(token: source.token, path: []).first)
      let name = try XCTUnwrap(entry["name"] as? String)
      let version = try XCTUnwrap(entry["revision"] as? String)
      let destination = directory.appendingPathComponent("stale.part")
      assertCode("photos_changed") {
        _ = try service.export(token: source.token, path: [name], version: "stale", destination: destination)
      }
      source.members = nil
      assertCode("photos_changed") {
        _ = try service.export(token: source.token, path: [name], version: version, destination: destination)
      }
      XCTAssertEqual(source.writes, 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testExportDetectsDeletionAndPermissionRevocationDuringDownload() throws {
    try withTestDirectory { directory in
      for revoke in [false, true] {
        let source = FakeAlbumSource()
        let service = AlbumBackupService(source: source)
        let entry = try XCTUnwrap(service.list(token: source.token, path: []).first)
        source.afterWrite = {
          if revoke { source.authorization = .limited } else { source.members = nil }
        }
        let destination = directory.appendingPathComponent(UUID().uuidString + ".part")
        assertCode(revoke ? "photos_permission" : "photos_changed") {
          _ = try service.export(token: source.token,
            path: [entry["name"] as! String], version: entry["revision"] as! String,
            destination: destination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      }
    }
  }

  func testProviderFailureAndEmptyOriginalNeverSucceed() throws {
    try withTestDirectory { directory in
      for empty in [false, true] {
        let source = FakeAlbumSource()
        let service = AlbumBackupService(source: source)
        let entry = try XCTUnwrap(service.list(token: source.token, path: []).first)
        if empty { source.bytes = Data() }
        else { source.writeError = NSError(domain: "iCloud", code: 7) }
        let destination = directory.appendingPathComponent(UUID().uuidString + ".part")
        assertCode("photos_export") {
          _ = try service.export(token: source.token, path: [entry["name"] as! String],
            version: entry["revision"] as! String, destination: destination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      }
    }
  }

  func testTimeoutCleansOnlyOwnPartialIncludingLateCompletion() throws {
    try withTestDirectory { directory in
      let source = FakeAlbumSource()
      source.deferCompletion = true
      let service = AlbumBackupService(source: source, exportTimeout: 0.01)
      let entry = try XCTUnwrap(service.list(token: source.token, path: []).first)
      let destination = directory.appendingPathComponent("timeout.part")
      let other = directory.appendingPathComponent("other.part")
      try Data([99]).write(to: other)
      assertCode("photos_timeout") {
        _ = try service.export(token: source.token, path: [entry["name"] as! String],
          version: entry["revision"] as! String, destination: destination)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      try source.bytes.write(to: destination)
      source.pendingCompletion?(nil)
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      XCTAssertEqual(try Data(contentsOf: other), Data([99]))
    }
  }

  func testCancellationNeverPublishesAStagedOriginal() throws {
    try withTestDirectory { directory in
      let source = FakeAlbumSource()
      let service = AlbumBackupService(source: source)
      let entry = try XCTUnwrap(service.list(token: source.token, path: []).first)
      source.afterWrite = { service.cancelExports() }
      let destination = directory.appendingPathComponent("cancelled.part")
      assertCode("photos_cancelled") {
        _ = try service.export(token: source.token, path: [entry["name"] as! String],
          version: entry["revision"] as! String, destination: destination)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testSchedulerEnforcesDelayPowerAndSurfacesSubmissionFailure() throws {
    let scheduler = FakeAlbumScheduler()
    let scheduling = AlbumBackupScheduling(scheduler: scheduler)
    let before = Date()
    try scheduling.schedule(earliestSeconds: 1, requiresCharging: true)
    let request = try XCTUnwrap(scheduler.requests.first)
    XCTAssertEqual(request.identifier, "app.ncloud.album-backup")
    XCTAssertTrue(request.requiresNetworkConnectivity)
    XCTAssertTrue(request.requiresExternalPower)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(request.earliestBeginDate).timeIntervalSince(before), 900)
    scheduling.cancel()
    XCTAssertEqual(scheduler.cancelled, ["app.ncloud.album-backup"])
    scheduler.failure = NSError(domain: "BGTaskSchedulerErrorDomain", code: 1)
    assertCode("backup_schedule") { try scheduling.schedule() }
    assertCode("backup_schedule") { try scheduling.schedule(earliestSeconds: .infinity) }
  }

  func testAccountLocksExcludeOtherEnginesAndReleaseOnDeinit() throws {
    try withTestDirectory { directory in
      var first: AccountSyncRunLock? = AccountSyncRunLock(directory: directory)
      let second = AccountSyncRunLock(directory: directory)
      XCTAssertTrue(try first!.acquire(account: "account"))
      XCTAssertFalse(try first!.acquire(account: "account"))
      XCTAssertFalse(try second.acquire(account: "account"))
      XCTAssertTrue(try second.acquire(account: "other-account"))
      first?.release(account: "account")
      XCTAssertTrue(try second.acquire(account: "account"))
      second.releaseAll()
      XCTAssertTrue(try first!.acquire(account: "account"))
      first = nil
      XCTAssertTrue(try second.acquire(account: "account"))
      XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .contains { $0.contains("account") })
    }
  }

  func testHeadlessBridgeRegistrationAndLockSurvivesUntilNativeQueueDrains() throws {
    let engine = FlutterEngine(name: "ncloud-native-headless-test",
                               project: nil, allowHeadlessExecution: true)
    XCTAssertTrue(engine.run())
    defer { engine.destroyContext() }
    XCTAssertNil(engine.viewController)
    let registrar = try XCTUnwrap(engine.registrar(forPlugin: AppDelegate.FolderSyncBridge.pluginKey))
    let queue = DispatchQueue(label: "app.ncloud.tests.native-drain")
    let blocked = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    queue.async {
      entered.signal()
      blocked.wait()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    let messenger = NativeTestMessenger()
    var bridge: AppDelegate.FolderSyncBridge? =
      AppDelegate.FolderSyncBridge.install(with: registrar, messenger: messenger, queue: queue)
    XCTAssertTrue(engine.hasPlugin(AppDelegate.FolderSyncBridge.pluginKey))
    XCTAssertTrue(engine.valuePublished(byPlugin: AppDelegate.FolderSyncBridge.pluginKey) === bridge)
    let account = "native-test-" + UUID().uuidString
    let contender = AccountSyncRunLock()
    XCTAssertNotNil(messenger.handlers["app.ncloud/folder_sync"])
    XCTAssertEqual(try messenger.invoke("acquire", account: account) as? Bool, true)
    XCTAssertFalse(try contender.acquire(account: account))
    XCTAssertNil(try messenger.invoke("release", account: account))
    XCTAssertTrue(try contender.acquire(account: account))
    contender.release(account: account)
    XCTAssertEqual(try messenger.invoke("acquire", account: account) as? Bool, true)
    bridge?.detachFromEngine(for: registrar)
    XCTAssertNil(messenger.handlers["app.ncloud/folder_sync"])
    bridge = nil
    XCTAssertFalse(try contender.acquire(account: account))
    let drained = expectation(description: "native operations drain before lock release")
    queue.async { drained.fulfill() }
    blocked.signal()
    wait(for: [drained], timeout: 5)
    XCTAssertTrue(try contender.acquire(account: account))
    contender.release(account: account)
  }

  func testPhotosStageReclaimsOnlyOldRegularPartFilesWithoutCreatingDestination() throws {
    try withTestDirectory { directory in
      let engine = FlutterEngine(name: "ncloud-staging-test",
                                 project: nil, allowHeadlessExecution: true)
      XCTAssertTrue(engine.run())
      defer { engine.destroyContext() }
      let registrar = try XCTUnwrap(engine.registrar(forPlugin: AppDelegate.FolderSyncBridge.pluginKey))
      let bridge = AppDelegate.FolderSyncBridge.install(with: registrar,
        messenger: NativeTestMessenger(), stagingDirectory: directory)
      let manager = FileManager.default
      let oldPart = directory.appendingPathComponent("abandoned.part")
      let freshPart = directory.appendingPathComponent("active.part")
      let unrelated = directory.appendingPathComponent("keep.jpg")
      let nested = directory.appendingPathComponent("nested.part", isDirectory: true)
      for file in [oldPart, freshPart, unrelated] { try Data([1]).write(to: file) }
      try manager.createDirectory(at: nested, withIntermediateDirectories: false)
      let nestedPart = nested.appendingPathComponent("keep.part")
      try Data([2]).write(to: nestedPart)
      let old = Date().addingTimeInterval(-48 * 60 * 60)
      for file in [oldPart, unrelated, nested, nestedPart] {
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
      }
      let destination = try bridge.newStage(create: false)
      XCTAssertEqual(destination.pathExtension, "part")
      XCTAssertEqual(destination.deletingLastPathComponent(), directory)
      XCTAssertFalse(manager.fileExists(atPath: destination.path))
      XCTAssertFalse(manager.fileExists(atPath: oldPart.path))
      for retained in [freshPart, unrelated, nested, nestedPart] {
        XCTAssertTrue(manager.fileExists(atPath: retained.path))
      }
      let nextDestination = try bridge.newStage(create: false)
      XCTAssertNotEqual(destination, nextDestination)
      XCTAssertFalse(manager.fileExists(atPath: nextDestination.path))
      let fileStage = try bridge.newStage()
      XCTAssertTrue(manager.fileExists(atPath: fileStage.path))
      bridge.detachFromEngine(for: registrar)
    }
  }

  private func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                          _ operation: () throws -> Void) {
    XCTAssertThrowsError(try operation(), file: file, line: line) {
      XCTAssertEqual(($0 as? AlbumBackupError)?.code, code, file: file, line: line)
    }
  }

  private func withTestDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ncloud-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
  }
}

private final class FakeAlbumSource: AlbumPhotoSource {
  var authorization = PHAuthorizationStatus.authorized
  var authorizationRequests = 0
  var availableAlbums = [BackupAlbum(identifier: "album-1", title: "Test Album")]
  var token: String { "photos:" + Data("album-1".utf8).base64EncodedString() }
  let still = BackupResource(type: PHAssetResourceType.photo.rawValue,
                            filename: "IMG_0001.HEIC", uti: "public.heic")
  lazy var members: [BackupAsset]? = [asset("asset-1")]
  var writes = 0
  var bytes = Data([0, 1, 2, 255])
  var writeError: Error?
  var afterWrite: (() -> Void)?
  var deferCompletion = false
  var pendingCompletion: ((Error?) -> Void)?
  var inventoryRequests = 0
  var targetedRequests: [String] = []

  func asset(_ id: String, modified: Date = Date(timeIntervalSince1970: 100),
             resources: [BackupResource]? = nil) -> BackupAsset {
    BackupAsset(identifier: id, modified: modified, resources: resources ?? [still])
  }

  func requestAuthorization(_ completion: @escaping (PHAuthorizationStatus) -> Void) {
    authorizationRequests += 1
    completion(authorization)
  }
  func albums() throws -> [BackupAlbum] { availableAlbums }
  func assets(in album: String) throws -> [BackupAsset]? {
    inventoryRequests += 1
    return album == "album-1" ? members : nil
  }
  func asset(_ identifier: String, in album: String) throws -> BackupAsset? {
    targetedRequests.append(identifier)
    return album == "album-1" ? members?.first(where: { $0.identifier == identifier }) : nil
  }

  func writeOriginal(asset: String, resource: BackupResource, to url: URL,
                     completion: @escaping (Error?) -> Void) {
    writes += 1
    do { try bytes.write(to: url) } catch { completion(error); return }
    afterWrite?()
    if deferCompletion { pendingCompletion = completion }
    else { completion(writeError) }
  }
}

private final class FakeAlbumScheduler: AlbumTaskScheduler {
  var requests: [BGProcessingTaskRequest] = []
  var cancelled: [String] = []
  var failure: Error?
  func submit(_ request: BGProcessingTaskRequest) throws {
    if let failure = failure { throw failure }
    requests.append(request)
  }

  private final class NativeTestMessenger: NSObject, FlutterBinaryMessenger {
    var handlers: [String: FlutterBinaryMessageHandler] = [:]

    func send(onChannel channel: String, message: Data?) {}
    func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
      callback?(nil)
    }
    func setMessageHandlerOnChannel(_ channel: String,
                                   binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
      handlers[channel] = handler
      return 1
    }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) { handlers.removeAll() }

    func invoke(_ method: String, account: String) throws -> Any? {
      let handler = try XCTUnwrap(handlers["app.ncloud/folder_sync"])
      let codec = FlutterStandardMethodCodec.sharedInstance()
      let message = codec.encodeMethodCall(FlutterMethodCall(methodName: method, arguments: ["account": account]))
      var replied = false
      var response: Data?
      handler(message) { response = $0; replied = true }
      XCTAssertTrue(replied)
      return try codec.decodeEnvelope(XCTUnwrap(response))
    }
  }
  func cancel(identifier: String) { cancelled.append(identifier) }
}
