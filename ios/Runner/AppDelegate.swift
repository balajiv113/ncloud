import Flutter
import UIKit
import UniformTypeIdentifiers
import Network

@main
@objc class AppDelegate: FlutterAppDelegate {
  let flutterEngine = FlutterEngine(name: "ncloud")
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    guard flutterEngine.run() else {
      preconditionFailure("Could not start the ncloud Flutter engine.")
    }
    GeneratedPluginRegistrant.register(with: flutterEngine)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  final class FolderSyncBridge: NSObject, UIDocumentPickerDelegate {
    private weak var controller: UIViewController?
    private let channel: FlutterMethodChannel
    private let queue = DispatchQueue(label: "app.ncloud.folder-sync")
    private var pickerResult: FlutterResult?
    private let manager = FileManager.default
    private var staging: URL {
      manager.temporaryDirectory.appendingPathComponent("ncloud-sync-staging", isDirectory: true)
    }

    init(controller: FlutterViewController) {
      self.controller = controller
      channel = FlutterMethodChannel(name: "app.ncloud/folder_sync",
                                     binaryMessenger: controller.binaryMessenger)
      super.init()
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result)
      }
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
      if call.method == "pick" {
        guard pickerResult == nil, let controller = controller else {
          result(FlutterError(code: "busy", message: "Folder picker unavailable.", details: nil))
          return
        }
        pickerResult = result
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
          picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        } else {
          picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        controller.present(picker, animated: true)
        return
      }
      if call.method == "conditions" {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = UIDevice.current.batteryState == .charging ||
          UIDevice.current.batteryState == .full
        let monitor = NWPathMonitor()
        var completed = false
        let finish: (Bool) -> Void = { wifi in
          guard !completed else { return }
          completed = true
          monitor.cancel()
          DispatchQueue.main.async { result(["wifi": wifi, "charging": charging]) }
        }
        monitor.pathUpdateHandler = { path in
          finish(path.status == .satisfied && path.usesInterfaceType(.wifi))
        }
        monitor.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        return
      }
      guard ["list", "export", "stage", "import", "discard"].contains(call.method) else {
        result(FlutterMethodNotImplemented)
        return
      }
      queue.async {
        do {
          let args = call.arguments as? [String: Any] ?? [:]
          try self.manager.createDirectory(at: self.staging, withIntermediateDirectories: true)
          let value: Any?
          if call.method == "stage" {
            value = try self.newStage().path
          } else if call.method == "discard" {
            let file = try self.stageFile(args["staged"] as? String)
            if self.manager.fileExists(atPath: file.path) { try self.manager.removeItem(at: file) }
            value = nil
          } else {
            guard let token = args["token"] as? String,
                  let data = Data(base64Encoded: token),
                  let path = args["path"] as? [String] else { throw self.failure() }
            try self.validate(path)
            var stale = false
            let root = try URL(resolvingBookmarkData: data, options: [.withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, root.startAccessingSecurityScopedResource() else { throw self.failure() }
            defer { root.stopAccessingSecurityScopedResource() }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var operationError: Error?
            var output: Any?
            // Coordinate the selected tree with its Files provider; access is held
            // only for this operation, never as an unrestricted filesystem grant.
            let operation: (URL) -> Void = { coordinated in
              do {
                switch call.method {
                case "list":
                  let directory = coordinated
                  let files = try self.manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
                  guard files.count <= 100000 else { throw self.failure() }
                  output = try files.map { try self.metadata($0) }
                case "export":
                  let source = coordinated
                  let before = try self.metadata(source)
                  guard let size = args["size"] as? NSNumber,
                        let modified = args["modified"] as? NSNumber,
                        before["directory"] as? Bool == false,
                        before["size"] as? Int64 == size.int64Value,
                        before["modified"] as? Int64 == modified.int64Value else { throw self.failure() }
                  let temp = try self.newStage()
                  do {
                    try self.copyBytes(source, temp)
                    let after = try self.metadata(source)
                    guard after["size"] as? Int64 == size.int64Value,
                          after["modified"] as? Int64 == modified.int64Value else { throw self.failure() }
                    output = temp.path
                  } catch {
                    try? self.manager.removeItem(at: temp)
                    throw error
                  }
                default:
                  guard !path.isEmpty else { throw self.failure() }
                  let temp = try self.stageFile(args["staged"] as? String)
                  var parent = coordinated
                  for component in path.dropLast() {
                    parent.appendPathComponent(component, isDirectory: true)
                    if !self.manager.fileExists(atPath: parent.path) {
                      try self.manager.createDirectory(at: parent, withIntermediateDirectories: false)
                    }
                    let info = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard info.isDirectory == true, info.isSymbolicLink != true else { throw self.failure() }
                  }
                  let destination = parent.appendingPathComponent(path.last!)
                  // copyItem fails if the destination exists. Never use replace,
                  // remove, or a truncating write on a user-selected destination.
                  try self.manager.copyItem(at: temp, to: destination)
                  output = try self.metadata(destination)
                }
              } catch { operationError = error }
            }
            if call.method == "import" {
              coordinator.coordinate(writingItemAt: root, options: [], error: &coordinationError,
                                     byAccessor: operation)
            } else {
              let source = try self.resolve(root, path)
              coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError,
                                     byAccessor: operation)
            }
            if let error = operationError { throw error }
            if let error = coordinationError { throw error }
            value = output
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "folder_access",
                                message: "Folder access or transfer failed. Check permission and free space; reselect the folder if needed.",
                                details: nil))
          }

        }
      }
    }

    private func failure() -> NSError {
      NSError(domain: "ncloud.folder-sync", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Folder access or source revision changed."])
    }

    private func validate(_ path: [String]) throws {
      guard path.count <= 64, path.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." &&
          !$0.contains("/") && !$0.contains("\\") &&
          !$0.unicodeScalars.contains(where: { $0.value < 32 })
      }) else { throw failure() }
    }

    private func resolve(_ root: URL, _ path: [String]) throws -> URL {
      var file = root
      for component in path {
        file.appendPathComponent(component)
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw failure() }
      }
      return file
    }

    private func metadata(_ file: URL) throws -> [String: Any] {
      let values = try file.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
      guard values.isSymbolicLink != true,
            values.isDirectory == true || values.isRegularFile == true else { throw failure() }
      return ["name": file.lastPathComponent, "directory": values.isDirectory == true,
              "size": Int64(values.fileSize ?? 0),
              "modified": Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)]
    }

    private func newStage() throws -> URL {
      let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
      for file in try manager.contentsOfDirectory(
        at: staging, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        if file.pathExtension == "part", values.isRegularFile == true,
           let modified = values.contentModificationDate, modified < cutoff {
          try manager.removeItem(at: file)
        }
      }
      let file = staging.appendingPathComponent(UUID().uuidString + ".part")
      guard manager.createFile(atPath: file.path, contents: nil) else { throw failure() }
      return file
    }

    private func stageFile(_ path: String?) throws -> URL {
      guard let path = path else { throw failure() }
      let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      guard file.deletingLastPathComponent() == staging.resolvingSymlinksInPath(),
            file.pathExtension == "part" else { throw failure() }
      return file
    }

    private func copyBytes(_ source: URL, _ destination: URL) throws {
      guard let input = InputStream(url: source),
            let output = OutputStream(url: destination, append: false) else { throw failure() }
      input.open()
      output.open()
      defer { input.close(); output.close() }
      let capacity = 1024 * 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
      defer { buffer.deallocate() }
      while true {
        let count = input.read(buffer, maxLength: capacity)
        guard count >= 0 else { throw input.streamError ?? failure() }
        if count == 0 { break }
        var offset = 0
        while offset < count {
          let written = output.write(buffer.advanced(by: offset), maxLength: count - offset)
          guard written > 0 else { throw output.streamError ?? failure() }
          offset += written
        }
      }
      if let error = input.streamError ?? output.streamError { throw error }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      let result = pickerResult
      pickerResult = nil
      guard let folder = urls.first, folder.startAccessingSecurityScopedResource() else {
        result?(FlutterError(code: "folder_access", message: "Folder permission was not granted.", details: nil))
        return
      }
      defer { folder.stopAccessingSecurityScopedResource() }
      do {
        let bookmark = try folder.bookmarkData(options: [.minimalBookmark],
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        result?(["token": bookmark.base64EncodedString(), "name": folder.lastPathComponent,
                 "identity": folder.absoluteString])
      } catch {
        result?(FlutterError(code: "folder_access", message: "Could not save folder permission.", details: nil))
      }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      pickerResult?(nil)
      pickerResult = nil
    }
  }
}

@objc class SceneDelegate: FlutterSceneDelegate {
  private var folders: AppDelegate.FolderSyncBridge?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let app = UIApplication.shared.delegate as? AppDelegate else {
      preconditionFailure("Could not connect the ncloud window scene.")
    }
    let controller = FlutterViewController(
      engine: app.flutterEngine, nibName: nil, bundle: nil
    )
    let sceneWindow = UIWindow(windowScene: windowScene)
    sceneWindow.rootViewController = controller
    window = sceneWindow
    folders = AppDelegate.FolderSyncBridge(controller: controller)
    sceneWindow.makeKeyAndVisible()
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
}
