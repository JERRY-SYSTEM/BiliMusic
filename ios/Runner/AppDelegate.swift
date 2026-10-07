import Flutter
import UIKit
import Darwin
import CryptoKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var diagnosticsChannel: FlutterMethodChannel?
  private var resourceSnapshotBusy = false
  private let resourceSnapshotQueue = DispatchQueue(label: "bilimusic.diagnostics.resources", qos: .utility)
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
      if call.method == "resourceSnapshot" {
        guard let self = self else {
          result(FlutterError(code: "unavailable", message: "Application unavailable", details: nil))
          return
        }
        guard !self.resourceSnapshotBusy else {
          result(FlutterError(code: "snapshot_busy", message: "Resource scan already running", details: nil))
          return
        }
        self.resourceSnapshotBusy = true
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        self.resourceSnapshotQueue.async {
          var snapshot = ResourceDiagnostics.snapshot()
          snapshot["protectedDataAvailable"] = protectedDataAvailable
          DispatchQueue.main.async {
            self.resourceSnapshotBusy = false
            result(snapshot)
          }
        }
        return
      }
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

/// Examines existing descriptors without opening, duplicating or closing any.
/// This is process-wide (including a host such as LiveContainer), not an
/// attribution of which library created a descriptor. Concurrent IO may race
/// the scan; counts and targets are observations, not an atomic snapshot.
enum ResourceDiagnostics {
  private static let containerIDPattern = try! NSRegularExpression(
    pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  )

  /// Keep the filename and directory structure needed to identify a leak,
  /// while removing installation/container UUIDs. Never read file contents.
  static func displayPath(_ path: String) -> String {
    let range = NSRange(path.startIndex..<path.endIndex, in: path)
    let sanitized = containerIDPattern.stringByReplacingMatches(
      in: path, range: range, withTemplate: "<container>"
    )
    return String(sanitized.prefix(1024))
  }

  static func category(for path: String) -> String {
    let lower = path.lowercased()
    if lower.contains("/bilimusic_audio/") { return "audio_cache" }
    if lower.contains("/bilimusic_covers/") { return "cover_cache" }
    if lower.contains("bilimusic_diagnostics") || lower.contains("bilimusic-diagnostics") { return "diagnostic_log" }
    if lower.hasSuffix(".sqlite") || lower.hasSuffix(".db") || lower.hasSuffix("-wal") || lower.hasSuffix("-shm") { return "database" }
    if lower.contains("dyld") || lower.hasSuffix(".dylib") || lower.contains(".framework/") { return "library" }
    if lower.hasPrefix("/dev/") { return "device" }
    if lower.contains("/livecontainer/") { return "container_other" }
    if lower.contains("/tmp/") { return "temporary" }
    return "other_file"
  }

  private static func path(of fd: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let status = buffer.withUnsafeMutableBufferPointer {
      fcntl(fd, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!))
    }
    guard status == 0 else { return nil }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }

  private static func socketCategory(_ fd: Int32) -> String {
    var type: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    let typeOK = getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0
    var address = sockaddr_storage()
    var addressSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let addressOK = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &addressSize) == 0
      }
    }
    let family = addressOK ? Int32(address.ss_family) : -1
    let prefix = family == AF_UNIX ? "unix" : family == AF_INET || family == AF_INET6 ? "network" : "unknown"
    let suffix = !typeOK ? "unknown" : type == SOCK_STREAM ? "stream" : type == SOCK_DGRAM ? "datagram" : "other"
    return "socket_\(prefix)_\(suffix)"
  }

  static func snapshot() -> [String: Any] {
    let started = ProcessInfo.processInfo.systemUptime
    var limits = rlimit()
    let limitOK = getrlimit(RLIMIT_NOFILE, &limits) == 0
    // Bound diagnostic work even if the host has an unusually large limit.
    let scanLimit = limitOK ? Int(min(limits.rlim_max, rlim_t(32768))) : 4096
    var count = 0
    var highest = -1
    var statFailures = 0
    var categories: [String: Int] = [:]
    var groups: [String: [Int]] = [:]
    var groupCounts: [String: Int] = [:]
    var groupPaths: [String: String] = [:]
    for number in 0..<max(scanLimit, 0) {
      let fd = Int32(number)
      guard fcntl(fd, F_GETFD) >= 0 else { continue }
      count += 1
      highest = number
      var info = stat()
      var category = "unknown"
      var target = "unknown"
      if fstat(fd, &info) == 0 {
        let type = info.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFSOCK) {
          category = socketCategory(fd)
          target = category
        } else if type == mode_t(S_IFIFO) {
          category = "pipe"
          target = "pipe"
        } else if let path = path(of: fd) {
          category = self.category(for: path)
          // Keep the original identity so counts can be compared with older logs.
          let digest = SHA256.hash(data: Data(path.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
          target = "\(category):\(digest)"
          if groupPaths[target] == nil { groupPaths[target] = displayPath(path) }
        } else {
          category = type == mode_t(S_IFCHR) ? "character_device" : type == mode_t(S_IFDIR) ? "directory" : "unresolved_file"
          target = category
        }
      } else {
        statFailures += 1
      }
      categories[category, default: 0] += 1
      groupCounts[target, default: 0] += 1
      if (groups[target]?.count ?? 0) < 8 { groups[target, default: []].append(number) }
    }
    let targets: [[String: Any]] = groupCounts.keys.sorted {
      let left = groupCounts[$0]!, right = groupCounts[$1]!
      return left == right ? $0 < $1 : left > right
    }.prefix(64).map { target in
      var entry: [String: Any] = ["target": target, "count": groupCounts[target]!, "fdExamples": groups[target] ?? []]
      if let path = groupPaths[target] {
        entry["path"] = path
        entry["filename"] = (path as NSString).lastPathComponent
      }
      return entry
    }
    return [
      "pid": getpid(), "process": ProcessInfo.processInfo.processName,
      "containerDetected": NSHomeDirectory().lowercased().contains("/livecontainer/"),
      "fdCount": count, "highestFD": highest,
      "softLimit": limitOK ? String(limits.rlim_cur) : "unknown",
      "hardLimit": limitOK ? String(limits.rlim_max) : "unknown",
      "scanLimit": scanLimit, "scanTruncated": !limitOK || limits.rlim_max > rlim_t(scanLimit),
      "statFailures": statFailures, "categories": categories,
      "targetGroupCount": groupCounts.count, "targets": targets,
      "targetsTruncated": groupCounts.count > 64,
      "scanMs": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
    ]
  }
}
