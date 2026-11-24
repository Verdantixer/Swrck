import Flutter
import UIKit
import NetworkExtension

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var vpnStatus: [String: Any] = ["state": "disconnected", "connected": false, "message": "Disconnected"]
  private var vpnStats: [String: Any] = ["downloadBytes": 0, "uploadBytes": 0, "durationMs": 0]
  private var vpnLogs: [[String: Any]] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: "com.swock.vpn/channel", binaryMessenger: messenger)

    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }
      switch call.method {
      case "connect":
        if let args = call.arguments as? [String: Any], let _ = args["profile"] as? String {
          self.vpnStatus = ["state": "connected", "connected": true, "message": "VPN connected"]
          self.recordLog("VPN connected")
          result(true)
        } else {
          result(FlutterError(code: "INVALID_PROFILE", message: "Profile JSON is required", details: nil))
        }
      case "disconnect":
        self.vpnStatus = ["state": "disconnected", "connected": false, "message": "Disconnected"]
        self.recordLog("User requested VPN stop")
        result(true)
      case "getStatus":
        result(self.vpnStatus)
      case "getStatistics":
        result(self.vpnStats)
      case "drainVpnLogs":
        let logs = self.vpnLogs
        self.vpnLogs.removeAll()
        result(logs)
      case "clearVpnLogs":
        self.vpnLogs.removeAll()
        result(true)
      case "testConnection":
        result(true)
      case "getNetworkInfo":
        result(["connected": true])
      case "getImportUri":
        result(nil)
      case "hotspotRequestPermissions":
        result(true)
      case "hotspotStart":
        result(true)
      case "hotspotStop":
        result(true)
      case "hotspotStatus":
        result(["active": false, "clients": 0])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func recordLog(_ message: String) {
    let entry: [String: Any] = [
      "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
      "message": message
    ]
    vpnLogs.append(entry)
    if vpnLogs.count > 500 {
      vpnLogs.removeFirst()
    }
  }
}
