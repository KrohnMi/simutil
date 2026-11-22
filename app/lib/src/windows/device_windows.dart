import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:simutil_core/simutil_core.dart';

/// Devices streaming in their own window. Each window runs its own Flutter
/// engine, so it opens its own session: the main window closes its tile
/// first, and opening a device that has a window shows that window.
class DeviceWindows {
  /// Method a device window answers by stopping its stream.
  static const closeMethod = 'device_window_close';

  /// Method the main window answers by streaming the device (its window
  /// arguments) in the grid again.
  static const backMethod = 'device_window_back';

  /// Set in a device window: stops its stream, hands the device back to
  /// the main window's grid and closes the window.
  Future<void> Function()? backToMain;

  final _moves = StreamController<DeviceMove>.broadcast();

  /// Set by [closeAll]: SimUtil is quitting, so no new window opens.
  var _closing = false;

  /// Devices moved into their own window or back to the grid, for toasts.
  Stream<DeviceMove> get moves => _moves.stream;

  /// The window arguments for [device].
  static String argumentsFor(Device device) => jsonEncode(device.toJson());

  /// The device a window was opened for; null for the main window.
  static Device? deviceOf(String arguments) {
    if (arguments.isEmpty) return null;
    try {
      return Device.fromJson(jsonDecode(arguments) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<WindowController?> _find(String deviceId) async {
    for (final window in await WindowController.getAll()) {
      if (deviceOf(window.arguments)?.id == deviceId) return window;
    }
    return null;
  }

  /// Whether any device window is open.
  Future<bool> hasAny() async => (await WindowController.getAll()).any(
    (window) => deviceOf(window.arguments) != null,
  );

  /// Brings [device]'s window to the front; false when it has none.
  Future<bool> focus(Device device) async {
    final window = await _find(device.id);
    if (window == null) return false;
    await window.show();
    return true;
  }

  /// Opens [device] in its own window, or shows the one it has. The window
  /// shows itself once it is sized. Does nothing while quitting: a window
  /// opened after [closeAll] looked would keep its stream running.
  Future<void> open(Device device) async {
    if (_closing || await focus(device) || _closing) return;
    await WindowController.create(
      WindowConfiguration(arguments: argumentsFor(device)),
    );
    _moves.add((device: device, back: false));
  }

  /// In the main window: streams a device sent back by its window in the
  /// grid. The window stopped its session first, and is still closing, so
  /// [StreamsCubit.open] must not look for it.
  Future<void> listen(Future<void> Function(Device device) openInGrid) async {
    final main = await WindowController.fromCurrentEngine();
    await main.setWindowMethodHandler((call) async {
      if (call.method != backMethod) return;
      if (deviceOf(call.arguments as String? ?? '') case final device?) {
        _moves.add((device: device, back: true));
        unawaited(openInGrid(device));
      }
    });
  }

  /// In a device window: asks the main window to stream [device] again.
  static Future<void> sendBack(Device device) async {
    for (final window in await WindowController.getAll()) {
      if (window.arguments.isEmpty) {
        await window.invokeMethod<void>(backMethod, argumentsFor(device));
      }
    }
  }

  /// Has every device window stop its stream, all at once; for quitting.
  /// Each gets 5 s, so a hung one leaves time to release the main window.
  Future<void> closeAll() async {
    _closing = true;
    final List<WindowController> windows;
    try {
      windows = await WindowController.getAll();
    } catch (_) {
      return; // quitting still releases the main window's services
    }
    await Future.wait([
      for (final window in windows)
        if (deviceOf(window.arguments) != null)
          window
              .invokeMethod<void>(closeMethod)
              .timeout(const Duration(seconds: 5))
              // A window that does not answer must not block quitting.
              .catchError((Object _) {}),
    ]);
  }
}

/// [device] moved into its own window, or [back] to the main window's grid.
typedef DeviceMove = ({Device device, bool back});
