import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Asks the main window's engine to release streams, recordings and
  /// child processes (`releaseApp` in Dart); it closes the device windows.
  private var quitChannel: FlutterMethodChannel? {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return nil }
    return FlutterMethodChannel(
      name: "simutil/quit", binaryMessenger: controller.engine.binaryMessenger)
  }

  /// The release ran (or gave up); the next terminate goes through.
  private var released = false
  private var releasing = false

  /// A hung release must not keep the app from quitting.
  private static let releaseTimeout: TimeInterval = 10

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in Self.terminateChildren() }
  }

  /// Last resort as SimUtil exits: a child process the release did not end
  /// (it timed out, or a stop came while a start was still launching one)
  /// would keep running under launchd. Emulators, plugins and the updater
  /// are started detached, so they are no children and keep running.
  private static func terminateChildren() {
    for child in childProcesses() { kill(child, SIGTERM) }
  }

  private static func childProcesses() -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
    size = procs.count * stride
    guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
    let me = getpid()
    return procs.prefix(size / stride)
      .filter { $0.kp_eproc.e_ppid == me }
      .map { $0.kp_proc.p_pid }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  /// Cmd+Q, the app menu, the Dock and logging out terminate without
  /// closing the window, so the Dart side never hears of it: adb, scrcpy
  /// and ffmpeg would keep running. Delay the quit until the release ran
  /// (or timed out): a logout, restart or shutdown then carries on.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !released, let channel = quitChannel else { return .terminateNow }
    if releasing { return .terminateCancel }
    releasing = true
    let finish = { [weak self] in
      guard let self, !self.released else { return }
      self.released = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    channel.invokeMethod("release", arguments: nil) { _ in finish() }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseTimeout, execute: finish)
    return .terminateLater
  }

  /// The Dock icon shows the main window again after it was hidden while
  /// device windows stayed open.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if let window = mainFlutterWindow, !window.isVisible {
      window.makeKeyAndOrderFront(nil)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
