import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo:session, options:connectionOptions)
    if let windowScene = scene as? UIWindowScene { ShellStartup.shared.bind(windowScene) }
  }
}
