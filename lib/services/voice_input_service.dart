/// Cross-platform voice input for the chat composer.
///
/// Two modes depending on platform + package availability:
///
/// ### Live transcription (`VoiceMode.liveTranscribe`)
/// Used whenever the `speech_to_text` plugin reports itself as
/// available: Android, iOS, Web — and (beta) Windows via
/// `speech_to_text_windows`. Partial results stream into
/// [transcriptStream] as the user speaks, so the chat input can
/// update in real time like ChatGPT / Claude mobile.
///
/// ### Audio capture (`VoiceMode.recordAudio`)
/// The fallback on platforms where no local STT is available
/// (Linux, older macOS, Windows when STT refuses to initialise).
/// Audio is written to a temp `.m4a` file; the caller attaches the
/// file to the next chat message so the daemon can transcribe it
/// server-side (Whisper). The [lastAudioPath] is set on stop.
///
/// The service exposes a small state machine:
///   idle → listening → (idle with transcript / audio path) → idle
///
/// Errors (permission denied, mic busy) flip the state back to idle
/// and surface via [lastError].
library;

import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart' as path_provider
    show getTemporaryDirectory;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'api_client.dart';

enum VoiceMode {
  /// Transcribed text streamed back live by the OS.
  liveTranscribe,

  /// Audio recorded locally, then uploaded to the daemon for
  /// server-side transcription (Whisper / cloud STT). Seen by the
  /// user as "I press mic, speak, text appears" — same as live but
  /// with a small post-stop delay.
  serverTranscribe,

  /// Audio recorded to a file; caller attaches and ships as raw
  /// audio because neither local nor server STT is available. Last
  /// resort — keeps the feature functional on stubbed daemons.
  recordAudio,

  /// No voice support on this platform (audio capture also failed).
  unavailable,
}

enum VoiceState { idle, listening, processing }

/// How the user wants voice handled. Persisted across sessions.
enum VoicePreference {
  /// Use whatever is fastest — native live STT if available, else
  /// server transcription, else audio attach.
  auto,

  /// Always upload to the daemon (Whisper) for uniform quality.
  /// Useful when the user doesn't trust / like the OS recogniser.
  alwaysServer,

  /// Never call the server — native only. Falls back to audio
  /// attach if the platform has no native STT.
  nativeOnly,
}

class VoiceInputService extends ChangeNotifier {
  static final VoiceInputService _i = VoiceInputService._();
  factory VoiceInputService() => _i;
  VoiceInputService._();

  // ── Public state ──────────────────────────────────────────────
  VoiceState _state = VoiceState.idle;
  VoiceState get state => _state;

  VoiceMode _mode = VoiceMode.unavailable;
  VoiceMode get mode => _mode;

  String _transcript = '';
  String get transcript => _transcript;

  String? _lastAudioPath;
  String? get lastAudioPath => _lastAudioPath;

  String? _lastError;
  String? get lastError => _lastError;

  bool _initialised = false;
  bool _hasNativeStt = false;

  // ── Live recording telemetry ──────────────────────────────────
  /// When the current recording started. Null while idle.
  DateTime? _startedAt;
  DateTime? get startedAt => _startedAt;

  /// Seconds elapsed since recording start. 0 while idle.
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// Peak amplitude normalised to [0, 1]. Updated ~20 times per
  /// second while recording so the UI can animate a waveform /
  /// pulsing dot. 0 while idle or when the backend doesn't report.
  double _amplitude = 0;
  double get amplitude => _amplitude;

  /// Recent amplitude samples (up to 60 = ~3s at 20 Hz). Older
  /// samples drop off the left. Fresh history each recording.
  final List<double> _amplitudeHistory = <double>[];
  List<double> get amplitudeHistory =>
      List<double>.unmodifiable(_amplitudeHistory);

  Timer? _amplitudeTimer;
  Timer? _elapsedTimer;

  VoicePreference _preference = VoicePreference.auto;
  VoicePreference get preference => _preference;

  /// Broadcast stream of partial / final transcripts. The stream
  /// emits the *full* transcript each time (not deltas) so the
  /// consumer can just overwrite the input field.
  final _transcriptCtrl = StreamController<String>.broadcast();
  Stream<String> get transcriptStream => _transcriptCtrl.stream;

  static const _kPreferenceKey = 'voice_preference';

  // ── Backends ──────────────────────────────────────────────────
  final stt.SpeechToText _speech = stt.SpeechToText();
  final AudioRecorder _recorder = AudioRecorder();

  // ── Lifecycle ─────────────────────────────────────────────────

  /// Resolve which mode to use. Safe to call multiple times; only
  /// initialises once. Caller can re-call after a permission denial
  /// was resolved externally (we re-probe).
  Future<void> ensureInitialised() async {
    if (_initialised) return;
    _initialised = true;

    // Load the user's preference (auto / alwaysServer / nativeOnly).
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPreferenceKey);
      if (raw != null) {
        _preference = VoicePreference.values.firstWhere(
          (v) => v.name == raw,
          orElse: () => VoicePreference.auto,
        );
      }
    } catch (_) {}

    // Windows' `speech_to_text_windows` plugin is in beta and often
    // fails silently — initialise() returns true but no recognition
    // events ever fire. On Windows we therefore skip native STT
    // entirely and rely on server transcription (Whisper). Users
    // can still opt back in by explicitly setting the preference.
    if (!kIsWeb && Platform.isWindows &&
        _preference == VoicePreference.auto) {
      _preference = VoicePreference.alwaysServer;
    }

    // Probe native STT — we cache the result for the `alwaysServer`
    // case so a later preference switch doesn't need a re-probe.
    try {
      _hasNativeStt = await _speech.initialize(
        onStatus: _onSttStatus,
        onError: _onSttError,
        debugLogging: kDebugMode,
      );
    } catch (e) {
      _hasNativeStt = false;
      debugPrint('VoiceInput: speech_to_text init failed: $e');
    }

    // Probe mic permission — lets us flip to `recordAudio` when
    // native STT isn't available.
    bool canRecord = false;
    try {
      canRecord = await _recorder.hasPermission();
    } catch (e) {
      debugPrint('VoiceInput: record permission probe failed: $e');
    }

    _mode = _resolveMode(canRecord: canRecord);
    debugPrint('VoiceInput: ready — mode=$_mode '
        '(native=$_hasNativeStt, record=$canRecord, pref=$_preference)');
    notifyListeners();
  }

  /// Pick the active mode from preference × platform capabilities.
  VoiceMode _resolveMode({required bool canRecord}) {
    switch (_preference) {
      case VoicePreference.alwaysServer:
        return canRecord ? VoiceMode.serverTranscribe : VoiceMode.unavailable;
      case VoicePreference.nativeOnly:
        if (_hasNativeStt) return VoiceMode.liveTranscribe;
        return canRecord ? VoiceMode.recordAudio : VoiceMode.unavailable;
      case VoicePreference.auto:
        if (_hasNativeStt) return VoiceMode.liveTranscribe;
        // Prefer server transcription over raw audio attach: the
        // user gets text in their input instead of a file to send.
        if (canRecord) return VoiceMode.serverTranscribe;
        return VoiceMode.unavailable;
    }
  }

  /// Change how the user wants voice handled. Persists across
  /// sessions. Triggers a mode re-resolve.
  Future<void> setPreference(VoicePreference p) async {
    if (_preference == p) return;
    _preference = p;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPreferenceKey, p.name);
    } catch (_) {}
    // Re-probe mic permission and recompute the mode.
    bool canRecord = false;
    try {
      canRecord = await _recorder.hasPermission();
    } catch (_) {}
    _mode = _resolveMode(canRecord: canRecord);
    notifyListeners();
  }

  /// Start listening. Clears any previous transcript / audio path.
  /// If already listening, does nothing.
  Future<void> start() async {
    if (_state == VoiceState.listening) return;
    await ensureInitialised();
    _lastError = null;
    _transcript = '';
    _lastAudioPath = null;

    switch (_mode) {
      case VoiceMode.liveTranscribe:
        await _startLiveTranscribe();
      case VoiceMode.serverTranscribe:
      case VoiceMode.recordAudio:
        await _startRecording();
      case VoiceMode.unavailable:
        _lastError = 'Voice input is not available on this platform.';
        notifyListeners();
    }
  }

  /// Stop listening. For live mode, returns the final transcript.
  /// For server mode, uploads the audio and returns the transcript
  /// (or the audio path on failure, which the caller attaches as a
  /// fallback). For record-only mode, returns the audio path.
  ///
  /// Callers can distinguish the outcome via [lastAudioPath]: if it
  /// is non-null, we produced an audio file they may want to attach.
  Future<String?> stop() async {
    if (_state != VoiceState.listening) return null;

    switch (_mode) {
      case VoiceMode.liveTranscribe:
        await _speech.stop();
        _state = VoiceState.idle;
        _stopMetering();
        notifyListeners();
        return _transcript.isEmpty ? null : _transcript;

      case VoiceMode.serverTranscribe:
        _state = VoiceState.processing;
        _stopMetering();
        notifyListeners();
        final path = await _recorder.stop();
        if (path == null) {
          _state = VoiceState.idle;
          notifyListeners();
          return null;
        }
        _lastAudioPath = path;
        // Try the daemon's Whisper endpoint. If it succeeds we hand
        // the text back and remove the temp file. If it fails the
        // caller will fall back to attaching the raw audio.
        final result = await DigitornApiClient().transcribeAudio(path);
        _state = VoiceState.idle;
        if (result != null && result.text.trim().isNotEmpty) {
          _transcript = result.text.trim();
          _transcriptCtrl.add(_transcript);
          _tryDelete(path);
          _lastAudioPath = null;
          notifyListeners();
          return _transcript;
        }
        // Daemon didn't return text — either the endpoint is not
        // implemented or it returned empty. Set a helpful error so
        // the UI can tell the user why their dictation silently
        // failed instead of just attaching a mystery `.m4a`.
        _lastError =
            'The daemon has no transcription endpoint yet. '
            'Your audio was attached to the message instead — the '
            'agent can play it back. Ask your admin to deploy the '
            '/api/transcribe endpoint (see '
            'docs/voice_transcription_contract.md).';
        notifyListeners();
        return null;

      case VoiceMode.recordAudio:
        _state = VoiceState.processing;
        _stopMetering();
        notifyListeners();
        final path = await _recorder.stop();
        _lastAudioPath = path;
        _state = VoiceState.idle;
        notifyListeners();
        return null; // no transcript — caller reads lastAudioPath
      case VoiceMode.unavailable:
        _state = VoiceState.idle;
        _stopMetering();
        notifyListeners();
        return null;
    }
  }

  void _tryDelete(String path) {
    if (kIsWeb) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best effort — the OS will clean the temp directory anyway.
    }
  }

  /// Cancel without consuming anything — discards the audio file
  /// if one was recorded, clears the transcript.
  Future<void> cancel() async {
    if (_state != VoiceState.listening) return;
    switch (_mode) {
      case VoiceMode.liveTranscribe:
        await _speech.cancel();
      case VoiceMode.serverTranscribe:
      case VoiceMode.recordAudio:
        await _recorder.cancel();
      case VoiceMode.unavailable:
        break;
    }
    _state = VoiceState.idle;
    _transcript = '';
    _lastAudioPath = null;
    _stopMetering();
    notifyListeners();
  }

  // ── Live transcription ─────────────────────────────────────────

  Future<void> _startLiveTranscribe() async {
    try {
      await _speech.listen(
        onResult: (result) {
          _transcript = result.recognizedWords;
          _transcriptCtrl.add(_transcript);
          notifyListeners();
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
        ),
      );
      _state = VoiceState.listening;
      notifyListeners();
    } catch (e) {
      _lastError = 'Could not start voice input: $e';
      _state = VoiceState.idle;
      notifyListeners();
    }
  }

  void _onSttStatus(String status) {
    debugPrint('VoiceInput: status=$status');
    // "done" / "notListening" fire when the engine decides it's
    // done — mirror that back to our state machine so the UI can
    // flip the button back to idle without the user tapping stop.
    if (status == 'done' || status == 'notListening') {
      if (_state == VoiceState.listening) {
        _state = VoiceState.idle;
        notifyListeners();
      }
    }
  }

  void _onSttError(dynamic error) {
    _lastError = error?.toString() ?? 'unknown error';
    _state = VoiceState.idle;
    notifyListeners();
  }

  // ── Audio recording ────────────────────────────────────────────

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        _lastError = 'Microphone permission denied.';
        notifyListeners();
        return;
      }
      final dir = await _tempDir();
      final path = '$dir/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      _state = VoiceState.listening;
      _startMetering();
      notifyListeners();
    } catch (e) {
      _lastError = 'Could not start recording: $e';
      _state = VoiceState.idle;
      notifyListeners();
    }
  }

  /// Begin polling the recorder for its current amplitude so the UI
  /// can animate a waveform and timer in real time. The `record`
  /// plugin's `getAmplitude` returns a negative decibel value
  /// (-160 .. 0); we normalise to [0, 1] with a simple clamp.
  void _startMetering() {
    _startedAt = DateTime.now();
    _amplitude = 0;
    _amplitudeHistory.clear();

    // Elapsed ticker — dedicated so the timer still updates even if
    // the backend stops reporting amplitude (e.g. web mode).
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        if (_state == VoiceState.listening) notifyListeners();
      },
    );

    _amplitudeTimer?.cancel();
    _amplitudeTimer = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) async {
        if (_state != VoiceState.listening) return;
        try {
          final amp = await _recorder.getAmplitude();
          // `current` is dBFS (negative). Map -45dB..0dB → 0..1.
          final db = amp.current;
          final norm = ((db + 45) / 45).clamp(0.0, 1.0);
          _amplitude = norm;
          _amplitudeHistory.add(norm);
          if (_amplitudeHistory.length > 60) {
            _amplitudeHistory.removeAt(0);
          }
          notifyListeners();
        } catch (_) {
          // Backend doesn't support metering (some web builds) —
          // fall back to a synthetic wave so the UI still feels
          // alive. Uses a simple sine so the bars breathe.
          final t = DateTime.now().millisecondsSinceEpoch / 200.0;
          final fake = 0.3 + 0.3 * (0.5 + 0.5 * _sin(t));
          _amplitude = fake;
          _amplitudeHistory.add(fake);
          if (_amplitudeHistory.length > 60) {
            _amplitudeHistory.removeAt(0);
          }
          notifyListeners();
        }
      },
    );
  }

  void _stopMetering() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _startedAt = null;
    _amplitude = 0;
  }

  // Light-weight sin so we avoid importing dart:math just for a fallback.
  double _sin(double t) {
    const twoPi = 6.283185307179586;
    final x = t % twoPi;
    // 4-term approximation — good enough for decorative animation.
    final x2 = x * x;
    return x - x2 * x / 6 + x2 * x2 * x / 120 - x2 * x2 * x2 * x / 5040;
  }

  Future<String> _tempDir() async {
    try {
      final dir = await path_provider.getTemporaryDirectory();
      return dir.path;
    } catch (_) {
      // `path_provider` isn't available on some desktop setups; use
      // the OS temp as a last resort.
      if (!kIsWeb) {
        try {
          return Platform.environment['TEMP'] ??
              Platform.environment['TMP'] ??
              '/tmp';
        } catch (_) {}
      }
      return '.';
    }
  }

  @override
  void dispose() {
    _transcriptCtrl.close();
    super.dispose();
  }
}
