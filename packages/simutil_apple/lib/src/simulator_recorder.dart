import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Records a booted simulator's screen with `simctl io recordVideo`.
abstract interface class SimulatorRecorder {
  /// Creates a recorder for simulator [udid].
  factory SimulatorRecorder(String udid) = _SimulatorRecorder;

  /// Whether a recording is running; false again once `simctl` stopped on
  /// its own (e.g. the simulator shut down).
  bool get isRecording;

  /// Starts writing an H.264 `.mp4` to [path]; completes once `simctl`
  /// records. Throws a [StateError] with `simctl`'s error when it cannot
  /// (e.g. the file cannot be created).
  Future<void> start(String path);

  /// Stops and finalizes the file; returns its path, or null when the
  /// recording failed or was not finalized.
  Future<String?> stop();
}

class _SimulatorRecorder implements SimulatorRecorder {
  _SimulatorRecorder(this.udid);

  final String udid;
  Process? _process;
  String? _path;

  /// The start in progress: a second [start] joins it instead of launching
  /// another `simctl`, and [stop] waits for it.
  Future<void>? _starting;

  /// The `simctl` a running start launched, before it reported recording,
  /// and whether it did; [stop] ends that wait.
  Process? _launching;
  Completer<bool>? _started;

  /// [stop] was called while a start was running: it must not record.
  var _cancelled = false;

  /// How long `simctl` may take to report `Recording started`.
  static const _startTimeout = Duration(seconds: 15);

  @override
  bool get isRecording => _process != null;

  @override
  Future<void> start(String path) {
    if (_process != null) return Future.value();
    return _starting ??= _start(path).whenComplete(() => _starting = null);
  }

  Future<void> _start(String path) async {
    // Long-lived until stopped: Process.start, not CommandExec.
    final process = await Process.start('xcrun', [
      'simctl',
      'io',
      udid,
      'recordVideo',
      '--codec=h264',
      '--force',
      path,
    ]);
    _launching = process;
    if (_cancelled) process.kill(ProcessSignal.sigint);
    unawaited(process.stdout.drain<void>());
    final stderr = StringBuffer();
    final started = _started = Completer<bool>();
    process.stderr.transform(utf8.decoder).listen((text) {
      stderr.write(text);
      if (stderr.toString().contains('Recording started') &&
          !started.isCompleted) {
        started.complete(true);
      }
    }, onError: (Object _) {});
    unawaited(
      process.exitCode.then((_) {
        if (!started.isCompleted) started.complete(false);
        // Ended on its own: no recording to stop any more.
        if (identical(_process, process)) {
          _process = null;
          _path = null;
        }
      }),
    );

    final ok = await started.future.timeout(
      _startTimeout,
      onTimeout: () => false,
    );
    _launching = null;
    _started = null;
    if (_cancelled) {
      // Already sent SIGINT by stop(): let simctl finish on its own.
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      throw StateError('Recording stopped while it was starting');
    }
    if (!ok) {
      process.kill();
      // So a retry does not overlap the failed simctl.
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      throw StateError('Recording failed: ${_lastLine(stderr.toString())}');
    }
    _process = process;
    _path = path;
  }

  /// simctl finalizes the movie on SIGINT, not on SIGTERM.
  @override
  Future<String?> stop() async {
    // A stream closed (or the app quitting) while its recording starts:
    // end the start now instead of waiting up to [_startTimeout] for
    // simctl, and stop what it may already have started.
    if (_starting case final starting?) {
      _cancelled = true;
      _launching?.kill(ProcessSignal.sigint);
      if (_started case final started? when !started.isCompleted) {
        started.complete(false);
      }
      try {
        await starting;
      } catch (_) {
      } finally {
        _cancelled = false;
      }
    }
    final process = _process;
    final path = _path;
    _process = null;
    _path = null;
    if (process == null) return null;
    process.kill(ProcessSignal.sigint);
    final code = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    return code == 0 && path != null && File(path).existsSync() ? path : null;
  }

  /// The message after simctl's `An error was encountered …` line (e.g.
  /// `Cannot create file`), else its last line.
  static String _lastLine(String output) {
    final lines = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('Note:'))
        .toList();
    final error = lines.indexWhere((l) => l.startsWith('An error was'));
    if (error >= 0 && error + 1 < lines.length) return lines[error + 1];
    return lines.lastOrNull ?? 'simctl did not start recording';
  }
}
