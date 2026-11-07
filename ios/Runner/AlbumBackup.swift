import BackgroundTasks
import CryptoKit
import Darwin
import Foundation
import Photos
import UniformTypeIdentifiers

struct AlbumBackupError: LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }
}

func backupDigest(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct BackupAlbum {
  let identifier: String
  let title: String
}

struct BackupResource {
  let type: Int
  let filename: String
  let uti: String
  var identity: String { "\(type):\(filename.utf8.count):\(filename):\(uti)" }
}

struct BackupAsset {
  let identifier: String
  let modified: Date
  let resources: [BackupResource]
}

protocol AlbumPhotoSource {
  var authorization: PHAuthorizationStatus { get }
  func requestAuthorization(_ completion: @escaping (PHAuthorizationStatus) -> Void)
  func albums() throws -> [BackupAlbum]
  // nil means the album was deleted, not that it is empty.
  func assets(in album: String) throws -> [BackupAsset]?
  // Fetch current membership and resources for this asset only; never trust a listed snapshot.
  func asset(_ identifier: String, in album: String) throws -> BackupAsset?
  func writeOriginal(asset: String, resource: BackupResource, to url: URL,
                     completion: @escaping (Error?) -> Void)
}

final class PhotoKitAlbumSource: AlbumPhotoSource {
  var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

  func requestAuthorization(_ completion: @escaping (PHAuthorizationStatus) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: completion)
  }

  func albums() throws -> [BackupAlbum] {
    var albums: [BackupAlbum] = []
    let append: (PHAssetCollection, Int, UnsafeMutablePointer<ObjCBool>) -> Void = { album, _, _ in
      albums.append(BackupAlbum(identifier: album.localIdentifier,
                                title: album.localizedTitle ?? "Album"))
    }
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
      .enumerateObjects(append)
    // Deliberately do not offer Hidden, Recently Deleted, or the entire library.
    for subtype in [PHAssetCollectionSubtype.smartAlbumRecentlyAdded, .smartAlbumFavorites] {
      PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
        .enumerateObjects(append)
    }
    return albums
  }

  func assets(in album: String) throws -> [BackupAsset]? {
    guard let collection = PHAssetCollection.fetchAssetCollections(
      withLocalIdentifiers: [album], options: nil).firstObject else { return nil }
    var assets: [BackupAsset] = []
    PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
      assets.append(self.snapshot(asset))
    }
    return assets
  }

  func asset(_ identifier: String, in album: String) throws -> BackupAsset? {
    guard let collection = PHAssetCollection.fetchAssetCollections(
      withLocalIdentifiers: [album], options: nil).firstObject,
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
      PHAsset.fetchAssets(in: collection, options: nil).index(of: asset) != NSNotFound else {
      return nil
    }
    return snapshot(asset)
  }

  private func snapshot(_ asset: PHAsset) -> BackupAsset {
    let resources = PHAssetResource.assetResources(for: asset).map {
      BackupResource(type: $0.type.rawValue, filename: $0.originalFilename,
                     uti: $0.uniformTypeIdentifier)
    }
    return BackupAsset(identifier: asset.localIdentifier,
                       modified: asset.modificationDate ?? asset.creationDate ??
                         Date(timeIntervalSince1970: 1), resources: resources)
  }

  func writeOriginal(asset: String, resource: BackupResource, to url: URL,
                     completion: @escaping (Error?) -> Void) {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [asset], options: nil).firstObject,
          let original = PHAssetResource.assetResources(for: asset).first(where: {
            $0.type.rawValue == resource.type && $0.originalFilename == resource.filename &&
              $0.uniformTypeIdentifier == resource.uti
          }) else {
      completion(AlbumBackupError(code: "photos_changed", message: "The Photos original changed. Retry the album."))
      return
    }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    PHAssetResourceManager.default().writeData(for: original, toFile: url, options: options,
                                              completionHandler: completion)
  }
}

final class AlbumBackupService {
  private let source: AlbumPhotoSource
  private let exportTimeout: TimeInterval
  private let manager = FileManager.default
  private let exportLock = NSLock()
  private var activeExports: [UUID: PhotoExportState] = [:]
  private var stopped = false
  private struct ListedResource {
    let assetID: String
    let resource: BackupResource
    let revision: String
  }
  private var listedResources: [String: [String: ListedResource]] = [:]
  private let snapshotLock = NSLock()

  init(source: AlbumPhotoSource = PhotoKitAlbumSource(), exportTimeout: TimeInterval = 90) {
    self.source = source
    self.exportTimeout = exportTimeout
  }

  static func safeName(_ input: String, maximumBytes: Int = 150) -> String {
    let scalars = input.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":"
    }
    var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    while name.utf8.count > maximumBytes { name.removeLast() }
    return name.isEmpty || name == "." || name == ".." ? "Album" : name
  }

  private func requireAuthorization() throws {
    guard source.authorization == .authorized else {
      throw AlbumBackupError(code: "photos_permission",
        message: "Whole-album backup requires Full Access to Photos, not Limited Access. Allow Full Access in Settings > ncloud > Photos.")
    }
  }

  func requestAlbums(_ completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    source.requestAuthorization { _ in
      completion(Result { try self.authorizedAlbums() })
    }
  }

  func authorizedAlbums() throws -> [[String: Any]] {
    try requireAuthorization()
    let albums = try source.albums()
    try requireAuthorization()
    let titles = Dictionary(grouping: albums, by: { Self.safeName($0.title) })
    return albums.map { album in
      var name = Self.safeName(album.title)
      if (titles[name]?.count ?? 0) > 1 {
        name += " (\(backupDigest(album.identifier).prefix(10)))"
      }
      return ["token": "photos:" + Data(album.identifier.utf8).base64EncodedString(),
              "identity": "photos:" + album.identifier, "name": name, "kind": "photoAlbum"]
    }
  }

  private func albumID(_ token: String) throws -> String {
    guard token.hasPrefix("photos:"),
          let data = Data(base64Encoded: String(token.dropFirst(7))),
          let id = String(data: data, encoding: .utf8), !id.isEmpty else {
      throw AlbumBackupError(code: "photos_album", message: "Invalid Photos album permission. Select the album again.")
    }
    return id
  }

  private func assets(_ token: String) throws -> [BackupAsset] {
    try requireAuthorization()
    let fetched = try source.assets(in: albumID(token))
    try requireAuthorization()
    guard let assets = fetched else {
      throw AlbumBackupError(code: "photos_album", message: "The selected Photos album no longer exists. Select another album.")
    }
    return assets
  }

  static func originals(_ asset: BackupAsset) -> [BackupResource] {
    let types = [PHAssetResourceType.photo.rawValue, PHAssetResourceType.alternatePhoto.rawValue,
                 PHAssetResourceType.video.rawValue, PHAssetResourceType.pairedVideo.rawValue]
    return asset.resources.filter { types.contains($0.type) }
  }

  static func revision(_ asset: BackupAsset, _ resource: BackupResource) -> String {
    backupDigest("\(asset.identifier)|\(asset.modified.timeIntervalSince1970)|\(resource.identity)|" +
      asset.resources.map(\.identity).sorted().joined(separator: "|"))
  }

  static func filename(_ asset: BackupAsset, _ resource: BackupResource) -> String {
    let url = URL(fileURLWithPath: resource.filename)
    let ext = safeName(url.pathExtension, maximumBytes: 24)
    let stem = safeName(url.deletingPathExtension().lastPathComponent, maximumBytes: 100)
    let suffix = backupDigest(asset.identifier + "|" + resource.identity)
    return "\(stem)-\(suffix)" + (url.pathExtension.isEmpty ? "" : ".\(ext)")
  }

  private func entries(_ token: String) throws -> [(BackupAsset, BackupResource)] {
    let pairs = try assets(token).flatMap { asset in Self.originals(asset).map { (asset, $0) } }
    let names = pairs.map { Self.filename($0.0, $0.1) }
    guard Set(names).count == names.count else {
      throw AlbumBackupError(code: "photos_changed", message: "Ambiguous Photos originals. Retry after Photos finishes updating.")
    }
    return pairs
  }

  private func validateCurrent(_ listed: ListedResource, token: String, version: String) throws {
    try requireAuthorization()
    let current = try source.asset(listed.assetID, in: albumID(token))
    try requireAuthorization()
    guard let current = current, current.identifier == listed.assetID,
          let resource = Self.originals(current).first(where: {
            $0.identity == listed.resource.identity
          }), Self.revision(current, resource) == version,
          current.resources.filter({ $0.identity == resource.identity }).count == 1 else {
      throw AlbumBackupError(code: "photos_changed",
        message: "The Photos album or original changed. Refresh and retry.")
    }
  }

  func cancelExports() {
    exportLock.lock()
    stopped = true
    let active = Array(activeExports.values)
    exportLock.unlock()
    active.forEach { $0.cancel() }
  }

  func list(token: String, path: [String]) throws -> [[String: Any]] {
    guard path.isEmpty else {
      throw AlbumBackupError(code: "photos_album", message: "Photos albums do not contain subfolders.")
    }
    snapshotLock.lock()
    listedResources.removeValue(forKey: token)
    snapshotLock.unlock()
    let pairs = try entries(token)
    let lookup = Dictionary(uniqueKeysWithValues: pairs.map { asset, resource in
      (Self.filename(asset, resource), ListedResource(assetID: asset.identifier,
        resource: resource, revision: Self.revision(asset, resource)))
    })
    snapshotLock.lock()
    listedResources[token] = lookup
    snapshotLock.unlock()
    return pairs.map { asset, resource in
      ["name": Self.filename(asset, resource), "directory": false, "size": Int64(-1),
       "modified": max(Int64(1), Int64(asset.modified.timeIntervalSince1970 * 1000)),
       "contentType": UTType(resource.uti)?.preferredMIMEType ?? "application/octet-stream",
       "revision": Self.revision(asset, resource)]
    }
  }

  func export(token: String, path: [String], version: String, destination: URL) throws -> String {
    try requireAuthorization()
    snapshotLock.lock()
    let listed = path.count == 1 ? listedResources[token]?[path[0]] : nil
    snapshotLock.unlock()
    guard path.count == 1,
          let listed = listed, listed.revision == version else {
      throw AlbumBackupError(code: "photos_changed", message: "The Photos album or original changed. Refresh and retry.")
    }
    try validateCurrent(listed, token: token, version: version)
    let state = PhotoExportState(destination: destination)
    let exportID = UUID()
    exportLock.lock()
    let cancelled = stopped
    if !cancelled { activeExports[exportID] = state }
    exportLock.unlock()
    guard !cancelled else {
      throw AlbumBackupError(code: "photos_cancelled", message: "The album export was cancelled.")
    }
    defer {
      exportLock.lock()
      activeExports.removeValue(forKey: exportID)
      exportLock.unlock()
    }
    source.writeOriginal(asset: listed.assetID, resource: listed.resource, to: destination) { error in
      state.complete(error)
    }
    do {
      try state.wait(seconds: exportTimeout)
      try validateCurrent(listed, token: token, version: version)
      let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
        throw AlbumBackupError(code: "photos_export", message: "Photos did not provide a complete original. Retry when iCloud is available.")
      }
      exportLock.lock()
      let cancelled = stopped
      exportLock.unlock()
      guard !cancelled else {
        throw AlbumBackupError(code: "photos_cancelled", message: "The album export was cancelled.")
      }
      return destination.path
    } catch {
      if manager.fileExists(atPath: destination.path) {
        do { try manager.removeItem(at: destination) } catch {
          throw AlbumBackupError(code: "photos_export",
            message: "Could not remove the failed Photos download. Check device storage and retry.")
        }
      }
      throw error
    }
  }
}

// writeData has no cancellation handle. A timed-out operation is abandoned and
// its unique partial is removed now and again on late completion, never published.
private final class PhotoExportState {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private let destination: URL
  private var abandoned = false
  private var error: Error?

  init(destination: URL) { self.destination = destination }

  func complete(_ error: Error?) {
    lock.lock()
    if abandoned {
      // The callback cannot report cleanup to a detached engine. Only this
      // operation's unique partial may be touched; no library files are changed.
      if FileManager.default.fileExists(atPath: destination.path) {
        do { try FileManager.default.removeItem(at: destination) } catch {
          NSLog("ncloud: could not remove an abandoned Photos staging file: %@", error.localizedDescription)
        }
      }
    } else {
      self.error = error
    }
    lock.unlock()
    done.signal()
  }

  func cancel() {
    lock.lock()
    abandoned = true
    error = AlbumBackupError(code: "photos_cancelled", message: "The album export was cancelled.")
    lock.unlock()
    done.signal()
  }

  func wait(seconds: TimeInterval) throws {
    let status = done.wait(timeout: .now() + seconds)
    lock.lock()
    defer { lock.unlock() }
    if status == .timedOut {
      abandoned = true
      throw AlbumBackupError(code: "photos_timeout",
        message: "Downloading the Photos original timed out. Check iCloud connectivity and retry.")
    }
    if let error = error {
      if let error = error as? AlbumBackupError { throw error }
      throw AlbumBackupError(code: "photos_export",
        message: "Photos/iCloud could not download the original: \(error.localizedDescription)")
    }
  }
}

protocol AlbumTaskScheduler {
  func submit(_ request: BGProcessingTaskRequest) throws
  func cancel(identifier: String)
}

struct SystemAlbumTaskScheduler: AlbumTaskScheduler {
  static var backgroundSupported: Bool {
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    return false
    #else
    return !ProcessInfo.processInfo.isiOSAppOnMac
    #endif
  }

  func submit(_ request: BGProcessingTaskRequest) throws { try BGTaskScheduler.shared.submit(request) }
  func cancel(identifier: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
}

struct AlbumBackupScheduling {
  static let identifier = "app.ncloud.album-backup"
  var scheduler: AlbumTaskScheduler = SystemAlbumTaskScheduler()

  func schedule(earliestSeconds: Double = 900, requiresCharging: Bool = false) throws {
    guard earliestSeconds.isFinite, earliestSeconds <= 365 * 24 * 3600 else {
      throw AlbumBackupError(code: "backup_schedule", message: "Invalid backup delay. Choose a delay of at most one year.")
    }
    let request = BGProcessingTaskRequest(identifier: Self.identifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = requiresCharging
    request.earliestBeginDate = Date().addingTimeInterval(max(900, earliestSeconds))
    do { try scheduler.submit(request) } catch {
      throw AlbumBackupError(code: "backup_schedule",
        message: "iOS background scheduling is unavailable. On a physical device, allow Background App Refresh and turn off Low Power Mode. Manual backups remain available. \(error.localizedDescription)")
    }
  }

  func cancel() { scheduler.cancel(identifier: Self.identifier) }
}

final class AccountSyncRunLock {
  private var descriptors: [String: Int32] = [:]
  private let mutex = NSLock()
  private let directory: URL

  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
      in: .userDomainMask)[0].appendingPathComponent("ncloud-sync-locks", isDirectory: true)
  }

  func acquire(account: String) throws -> Bool {
    mutex.lock()
    defer { mutex.unlock() }
    guard !account.isEmpty else {
      throw AlbumBackupError(code: "sync_lock", message: "An account is required for the backup lock.")
    }
    guard descriptors[account] == nil else { return false }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(backupDigest(account) + ".lock")
    let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw AlbumBackupError(code: "sync_lock", message: "Could not open the account backup lock.")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let busy = errno == EWOULDBLOCK || errno == EAGAIN
      close(fd)
      if busy { return false }
      throw AlbumBackupError(code: "sync_lock", message: "Could not acquire the account backup lock.")
    }
    descriptors[account] = fd
    return true
  }

  func release(account: String) {
    mutex.lock()
    defer { mutex.unlock() }
    if let fd = descriptors.removeValue(forKey: account) { flock(fd, LOCK_UN); close(fd) }
  }

  func releaseAll() {
    mutex.lock()
    defer { mutex.unlock() }
    for fd in descriptors.values { flock(fd, LOCK_UN); close(fd) }
    descriptors.removeAll()
  }

  deinit { releaseAll() }
}
