import Flutter
import UIKit
import XCTest

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

}
