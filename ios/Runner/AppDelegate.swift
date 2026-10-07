import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var diagnosticsChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BiliMusicDiagnostics") else {
      return
    }
    let channel = FlutterMethodChannel(name: "bilimusic/diagnostics", binaryMessenger: registrar.messenger())
    diagnosticsChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "shareLog" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any], let text = arguments["text"] as? String else {
        result(FlutterError(code: "invalid_log", message: "Missing log text", details: nil))
        return
      }
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "Application unavailable", details: nil))
        return
      }
      self.shareDiagnosticLog(text, result: result)
    }
  }

  private func shareDiagnosticLog(_ text: String, result: @escaping FlutterResult) {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "no_presenter", message: "No active window", details: nil))
      return
    }
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    guard !presenter.isBeingDismissed, !presenter.isBeingPresented else {
      result(FlutterError(code: "presentation_busy", message: "Window transition in progress", details: nil))
      return
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bilimusic-diagnostics-\(UUID().uuidString)", isDirectory: true)
    let file = directory.appendingPathComponent("bilimusic-diagnostics.txt")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
      try text.write(to: file, atomically: true, encoding: .utf8)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      let failure = error as NSError
      let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
      result(FlutterError(code: "log_staging_failed", message: failure.localizedDescription,
        details: ["domain": failure.domain, "code": failure.code,
          "underlyingDomain": underlying?.domain ?? "", "underlyingCode": underlying?.code ?? 0]))
      return
    }

    let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    sheet.completionWithItemsHandler = { _, completed, _, error in
      try? FileManager.default.removeItem(at: directory)
      if let failure = error as NSError? {
        result(FlutterError(code: "log_share_failed", message: failure.localizedDescription,
          details: ["domain": failure.domain, "code": failure.code]))
      } else {
        result(completed)
      }
    }
    presenter.present(sheet, animated: true)
  }
}
