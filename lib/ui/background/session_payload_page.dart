import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/background_app_service.dart';
import '../../services/payload_service.dart';
import '../../theme/app_theme.dart';
import '../credentials/credential_gate.dart';
import 'widgets/typed_payload_form.dart';

/// Full-screen "Session Payload" configurator for a single background
/// session. Three editable sections + a danger zone:
///
/// 1. **Prompt** — large textarea with char counter + dirty save.
/// 2. **Preferences** — dynamic key/value editor, dirty save.
/// 3. **Attachments** — drag&drop + file picker, per-file remove,
///    25 MB client-side cap, upload progress bar.
/// 4. **Danger zone** — "Test now" (fires the first available trigger)
///    and "Clear payload" (with confirmation dialog).
///
/// Reads / writes the daemon via [PayloadService]. Fetches once on
/// init, then mutations refresh the local state from the response.
class SessionPayloadPage extends StatefulWidget {
  final String appId;
  final BackgroundSession session;
  /// Optional list of triggers — used by the "Test now" button to
  /// fire the first available trigger AND to compute the
  /// [SessionPayloadMode] that drives the page's wording.
  final List<Trigger> triggers;

  /// Declarative payload schema parsed from the app's YAML. When
  /// non-null, the page renders a [TypedPayloadForm] instead of the
  /// generic key/value editor.
  final PayloadSchema? schema;

  const SessionPayloadPage({
    super.key,
    required this.appId,
    required this.session,
    this.triggers = const [],
    this.schema,
  });

  SessionPayloadMode get mode => computeSessionPayloadMode(triggers);

  @override
  State<SessionPayloadPage> createState() => _SessionPayloadPageState();
}

class _SessionPayloadPageState extends State<SessionPayloadPage> {
  final _payloadSvc = PayloadService();
  final _bgSvc = BackgroundAppService();

  // Loading + remote state
  bool _loading = true;
  String? _loadError;
  SessionPayload _remote = SessionPayload.empty;

  // Local edit state
  late final TextEditingController _promptCtrl = TextEditingController();
  bool _promptDirty = false;
  bool _savingPrompt = false;

  /// Mutable copy of metadata as a list of `(key, value)` pairs so
  /// the user can have duplicate-empty rows while editing without
  /// breaking the underlying map shape.
  List<_MetadataEntry> _metaEntries = [];
  bool _metaDirty = false;
  bool _savingMeta = false;

  // Upload state
  bool _dropZoneActive = false;
  bool _uploading = false;
  double _uploadProgress = 0;
  String? _uploadingFilename;

  // Test now / clear
  bool _firingTest = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _load();
    _promptCtrl.addListener(() {
      final dirty = _promptCtrl.text != _remote.prompt;
      if (dirty != _promptDirty) {
        setState(() => _promptDirty = dirty);
      }
    });
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final payload = await _payloadSvc.get(widget.appId, widget.session.id);
      _applyRemote(payload);
      setState(() => _loading = false);
    } on PayloadException catch (e) {
      setState(() {
        _loading = false;
        _loadError = e.message;
      });
    }
  }

  void _applyRemote(SessionPayload p) {
    _remote = p;
    _promptCtrl.text = p.prompt;
    _promptDirty = false;
    _metaEntries = p.metadata.entries
        .map((e) => _MetadataEntry(
              key: e.key,
              value: e.value?.toString() ?? '',
            ))
        .toList();
    if (_metaEntries.isEmpty) _metaEntries.add(_MetadataEntry.empty());
    _metaDirty = false;
  }

  // ── Prompt save ──────────────────────────────────────────────────────

  Future<void> _savePrompt() async {
    if (_savingPrompt) return;
    setState(() => _savingPrompt = true);
    try {
      final payload = await _payloadSvc.setPromptAndMetadata(
        widget.appId,
        widget.session.id,
        prompt: _promptCtrl.text,
      );
      setState(() {
        _applyRemote(payload);
        _savingPrompt = false;
      });
      _toastOk('background_extra.prompt_saved_toast'.tr());
    } on PayloadException catch (e) {
      setState(() => _savingPrompt = false);
      _toastErr(e.message);
    }
  }

  // ── Metadata save ────────────────────────────────────────────────────

  Map<String, dynamic> _metaEntriesAsMap() {
    final out = <String, dynamic>{};
    for (final e in _metaEntries) {
      final k = e.key.trim();
      if (k.isEmpty) continue;
      out[k] = _coerceValue(e.value.trim());
    }
    return out;
  }

  /// Try to be friendly about typing: bare `true`/`false` → bool,
  /// integers → int, decimals → double, otherwise keep as string.
  static dynamic _coerceValue(String raw) {
    if (raw.isEmpty) return '';
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    final i = int.tryParse(raw);
    if (i != null) return i;
    final d = double.tryParse(raw);
    if (d != null) return d;
    return raw;
  }

  Future<void> _saveMeta() async {
    if (_savingMeta) return;
    setState(() => _savingMeta = true);
    try {
      final payload = await _payloadSvc.setPromptAndMetadata(
        widget.appId,
        widget.session.id,
        metadata: _metaEntriesAsMap(),
      );
      setState(() {
        _applyRemote(payload);
        _savingMeta = false;
      });
      _toastOk('background_extra.preferences_saved_toast'.tr());
    } on PayloadException catch (e) {
      setState(() => _savingMeta = false);
      _toastErr(e.message);
    }
  }

  void _addMetaEntry() {
    setState(() {
      _metaEntries.add(_MetadataEntry.empty());
      _metaDirty = true;
    });
  }

  void _removeMetaEntry(int i) {
    setState(() {
      _metaEntries.removeAt(i);
      if (_metaEntries.isEmpty) _metaEntries.add(_MetadataEntry.empty());
      _metaDirty = true;
    });
  }

  // ── File upload ──────────────────────────────────────────────────────

  Future<void> _pickAndUpload() async {
    final files = await openFiles(); // multi-select on desktop
    if (files.isEmpty) return;
    for (final f in files) {
      final bytes = await f.readAsBytes();
      await _uploadOne(filename: f.name, bytes: bytes, mime: f.mimeType);
    }
  }

  Future<void> _uploadOne({
    required String filename,
    required List<int> bytes,
    String? mime,
  }) async {
    setState(() {
      _uploading = true;
      _uploadingFilename = filename;
      _uploadProgress = 0;
    });
    try {
      final payload = await _payloadSvc.uploadFileBytes(
        appId: widget.appId,
        sessionId: widget.session.id,
        bytes: Uint8List.fromList(bytes),
        filename: filename,
        contentType: mime,
        onProgress: (sent, total) {
          if (total > 0) {
            setState(() => _uploadProgress = sent / total);
          }
        },
      );
      setState(() {
        _applyRemote(payload);
        _uploading = false;
        _uploadingFilename = null;
        _uploadProgress = 0;
      });
      _toastOk('background_extra.uploaded_toast'.tr(namedArgs: {'name': filename}));
    } on PayloadException catch (e) {
      setState(() {
        _uploading = false;
        _uploadingFilename = null;
        _uploadProgress = 0;
      });
      _toastErr(e.message);
    }
  }

  Future<void> _deleteFile(PayloadFile f) async {
    try {
      final payload = await _payloadSvc.deleteFile(
        appId: widget.appId,
        sessionId: widget.session.id,
        filename: f.name,
      );
      setState(() => _applyRemote(payload));
      _toastOk('background_extra.removed_toast'.tr(namedArgs: {'name': f.name}));
    } on PayloadException catch (e) {
      _toastErr(e.message);
    }
  }

  // ── Test now / Clear ─────────────────────────────────────────────────

  Future<void> _testNow() async {
    if (widget.triggers.isEmpty) return;
    // Gate: no point firing if the app's credentials aren't ready.
    final allowed = await ensureCredentials(context, appId: widget.appId);
    if (!allowed || !mounted) return;
    final trigger = widget.triggers.first;
    setState(() => _firingTest = true);
    final ok = await _bgSvc.fireTrigger(widget.appId, trigger.id);
    if (!mounted) return;
    setState(() => _firingTest = false);
    if (ok) {
      _toastOk(
          'background_extra.trigger_fired_toast'.tr(namedArgs: {'type': trigger.displayType}));
    } else {
      _toastErr('background_extra.trigger_fire_failed'.tr());
    }
  }

  Future<void> _clearPayload() async {
    final ok = await _confirmClear();
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await _payloadSvc.clear(
        appId: widget.appId,
        sessionId: widget.session.id,
      );
      if (!mounted) return;
      setState(() {
        _applyRemote(SessionPayload.empty);
        _clearing = false;
      });
      _toastOk('background_extra.payload_cleared_toast'.tr());
    } on PayloadException catch (e) {
      if (!mounted) return;
      setState(() => _clearing = false);
      _toastErr(e.message);
    }
  }

  Future<bool?> _confirmClear() {
    final c = context.colors;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: c.red),
            const SizedBox(width: 10),
            Text('background_extra.clear_payload_confirm_title'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.textBright)),
          ],
        ),
        content: Text(
          'background_extra.clear_payload_confirm_body'.tr(),
          style: GoogleFonts.inter(fontSize: 12, color: c.text, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('background_extra.cancel'.tr(),
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.red,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            child: Text('background_extra.clear'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _toastOk(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: context.colors.green.withValues(alpha: 0.9),
      duration: const Duration(seconds: 2),
    ));
  }

  void _toastErr(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: context.colors.red.withValues(alpha: 0.9),
      duration: const Duration(seconds: 4),
    ));
  }

  /// Human-readable summary of the trigger types this session reacts
  /// to. Used inside the mode banner so the user knows *why* the page
  /// is required / optional.
  String _triggerSummary() {
    if (widget.triggers.isEmpty) return '';
    final types = widget.triggers.map((t) => t.displayType).toSet().toList();
    if (types.length == 1) return types.first;
    if (types.length == 2) return '${types[0]} + ${types[1]}';
    return '${types.take(2).join(', ')} + ${types.length - 2}';
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: _buildAppBar(c),
      body: _loading
          ? _buildLoading(c)
          : _loadError != null
              ? _buildLoadError(c, _loadError!)
              : _buildContent(c),
    );
  }

  PreferredSizeWidget _buildAppBar(AppColors c) {
    final title = switch (widget.mode) {
      SessionPayloadMode.required => 'background_extra.session_payload'.tr(),
      SessionPayloadMode.recommended => 'background_extra.session_payload'.tr(),
      SessionPayloadMode.optional => 'background_extra.session_preferences'.tr(),
      SessionPayloadMode.hidden => 'background_extra.session_short'.tr(),
    };
    return AppBar(
      backgroundColor: c.surface,
      elevation: 0,
      foregroundColor: c.text,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: c.textBright),
          ),
          const SizedBox(height: 2),
          Text(
            widget.session.name,
            style: GoogleFonts.firaCode(
                fontSize: 11, color: c.textMuted),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        if (widget.triggers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: _ToolbarBtn(
                icon: Icons.play_arrow_rounded,
                label: 'background_extra.test_now'.tr(),
                color: c.blue,
                loading: _firingTest,
                onTap: _firingTest ? null : _testNow,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Center(
            child: _ToolbarBtn(
              icon: Icons.delete_outline_rounded,
              label: 'background_extra.clear'.tr(),
              color: c.red,
              loading: _clearing,
              onTap: _clearing || _remote.isEmpty ? null : _clearPayload,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoading(AppColors c) {
    return Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted),
      ),
    );
  }

  Widget _buildLoadError(AppColors c, String error) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text('background_extra.failed_to_load_payload'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(error,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.textMuted, height: 1.5)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _load,
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.surfaceAlt,
                  foregroundColor: c.text,
                  elevation: 0,
                  side: BorderSide(color: c.border),
                ),
                child: Text('background_extra.retry'.tr(),
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(AppColors c) {
    final mode = widget.mode;
    final promptEmpty = _promptCtrl.text.trim().isEmpty;
    final schema = widget.schema;
    if (schema != null && !schema.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ModeBanner(
                  mode: mode,
                  promptEmpty: promptEmpty,
                  triggerSummary: _triggerSummary(),
                ),
                const SizedBox(height: 24),
                TypedPayloadForm(
                  schema: schema,
                  payload: _remote,
                  busy: _uploading,
                  activating: false,
                  onSavePrompt: (text) async {
                    _promptCtrl.text = text;
                    await _savePrompt();
                  },
                  onSaveMetadata: (meta) async {
                    if (_savingMeta) return;
                    setState(() => _savingMeta = true);
                    try {
                      final payload =
                          await _payloadSvc.setPromptAndMetadata(
                        widget.appId,
                        widget.session.id,
                        metadata: meta,
                      );
                      setState(() {
                        _applyRemote(payload);
                        _savingMeta = false;
                      });
                      _toastOk('background_extra.preferences_saved_toast'.tr());
                    } on PayloadException catch (e) {
                      setState(() => _savingMeta = false);
                      _toastErr(e.message);
                    }
                  },
                  onUploadFile: ({
                    required bytes,
                    required filename,
                    contentType,
                    onProgress,
                  }) async {
                    setState(() {
                      _uploading = true;
                      _uploadingFilename = filename;
                      _uploadProgress = 0;
                    });
                    try {
                      final payload = await _payloadSvc.uploadFileBytes(
                        appId: widget.appId,
                        sessionId: widget.session.id,
                        bytes: bytes,
                        filename: filename,
                        contentType: contentType,
                        onProgress: (sent, total) {
                          if (total > 0) {
                            setState(() => _uploadProgress = sent / total);
                          }
                          onProgress?.call(sent, total);
                        },
                      );
                      setState(() {
                        _applyRemote(payload);
                        _uploading = false;
                        _uploadingFilename = null;
                        _uploadProgress = 0;
                      });
                      _toastOk('background_extra.uploaded_toast'.tr(namedArgs: {'name': filename}));
                    } on PayloadException catch (e) {
                      setState(() {
                        _uploading = false;
                        _uploadingFilename = null;
                        _uploadProgress = 0;
                      });
                      _toastErr(e.message);
                    }
                  },
                  onDeleteFile: _deleteFile,
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ModeBanner(
                mode: mode,
                promptEmpty: promptEmpty,
                triggerSummary: _triggerSummary(),
              ),
              const SizedBox(height: 24),
              _PromptSection(
                ctrl: _promptCtrl,
                dirty: _promptDirty,
                saving: _savingPrompt,
                onSave: _savePrompt,
                mode: mode,
              ),
              const SizedBox(height: 36),
              _MetadataSection(
                entries: _metaEntries,
                dirty: _metaDirty,
                saving: _savingMeta,
                onChanged: () => setState(() => _metaDirty = true),
                onAdd: _addMetaEntry,
                onRemove: _removeMetaEntry,
                onSave: _saveMeta,
              ),
              const SizedBox(height: 36),
              _AttachmentsSection(
                files: _remote.files,
                dropZoneActive: _dropZoneActive,
                uploading: _uploading,
                uploadingFilename: _uploadingFilename,
                uploadProgress: _uploadProgress,
                onPick: _pickAndUpload,
                onDelete: _deleteFile,
                onDropZoneEnter: () =>
                    setState(() => _dropZoneActive = true),
                onDropZoneExit: () =>
                    setState(() => _dropZoneActive = false),
                onFilesDropped: (xfiles) async {
                  setState(() => _dropZoneActive = false);
                  for (final f in xfiles) {
                    final bytes = await f.readAsBytes();
                    await _uploadOne(
                      filename: f.name,
                      bytes: bytes,
                      mime: f.mimeType,
                    );
                  }
                },
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ],
    );
  }
}

class _MetadataEntry {
  String key;
  String value;
  _MetadataEntry({required this.key, required this.value});
  factory _MetadataEntry.empty() => _MetadataEntry(key: '', value: '');
}

// ─── Mode banner ──────────────────────────────────────────────────────────
//
// First thing the user sees on the page — explains *why* this page is
// needed (or optional) given the kinds of triggers the app declares.
// Drives the rest of the wording (prompt label, hints) to keep the
// page coherent.

class _ModeBanner extends StatelessWidget {
  final SessionPayloadMode mode;
  final bool promptEmpty;
  final String triggerSummary;

  const _ModeBanner({
    required this.mode,
    required this.promptEmpty,
    required this.triggerSummary,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (mode == SessionPayloadMode.hidden) return const SizedBox.shrink();

    // For required/recommended mode + empty prompt, escalate the
    // visual urgency: orange warning background instead of the
    // neutral info chrome.
    final critical = (mode == SessionPayloadMode.required ||
            mode == SessionPayloadMode.recommended) &&
        promptEmpty;

    final (icon, tint, title, body) = switch (mode) {
      SessionPayloadMode.required => (
        critical
            ? Icons.warning_amber_rounded
            : Icons.flash_on_rounded,
        critical ? c.orange : c.blue,
        critical
            ? 'background_extra.payload_required_title'.tr()
            : 'background_extra.configured_scheduled_triggers'.tr(),
        triggerSummary.isEmpty
            ? 'background_extra.mode_required_body_no_summary'.tr()
            : 'background_extra.mode_required_body_with_summary'.tr(namedArgs: {'summary': triggerSummary}),
      ),
      SessionPayloadMode.recommended => (
        critical
            ? Icons.info_outline_rounded
            : Icons.tune_rounded,
        critical ? c.orange : c.cyan,
        'background_extra.mode_mixed_title'.tr(),
        'background_extra.mode_mixed_body'.tr(),
      ),
      SessionPayloadMode.optional => (
        Icons.tune_rounded,
        c.green,
        'background_extra.mode_optional_title'.tr(),
        triggerSummary.isEmpty
            ? 'background_extra.mode_optional_body_no_summary'.tr()
            : 'background_extra.mode_optional_body_with_summary'.tr(namedArgs: {'summary': triggerSummary}),
      ),
      SessionPayloadMode.hidden => (
        Icons.help_outline_rounded,
        c.textMuted,
        '',
        '',
      ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tint.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, size: 16, color: tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: c.textMuted,
                      height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Prompt section ───────────────────────────────────────────────────────

class _PromptSection extends StatelessWidget {
  final TextEditingController ctrl;
  final bool dirty;
  final bool saving;
  final VoidCallback onSave;
  final SessionPayloadMode mode;

  static const int _maxChars = 4000;

  const _PromptSection({
    required this.ctrl,
    required this.dirty,
    required this.saving,
    required this.onSave,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (label, hint, placeholder) = switch (mode) {
      SessionPayloadMode.required => (
        'background_extra.prompt_required_label'.tr(),
        'background_extra.prompt_required_hint'.tr(),
        'background_extra.prompt_required_placeholder'.tr(),
      ),
      SessionPayloadMode.recommended => (
        'background_extra.prompt_label'.tr(),
        'background_extra.prompt_recommended_hint'.tr(),
        'background_extra.prompt_recommended_placeholder'.tr(),
      ),
      SessionPayloadMode.optional => (
        'background_extra.permanent_instructions_label'.tr(),
        'background_extra.permanent_instructions_hint'.tr(),
        'background_extra.permanent_instructions_placeholder'.tr(),
      ),
      SessionPayloadMode.hidden => (
        'background_extra.prompt_label'.tr(),
        'background_extra.prompt_hidden_hint'.tr(),
        '',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(label: label, hint: hint),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          padding: const EdgeInsets.all(14),
          child: TextField(
            controller: ctrl,
            minLines: 6,
            maxLines: 16,
            maxLength: _maxChars,
            style: GoogleFonts.inter(
                fontSize: 13.5, color: c.text, height: 1.55),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: GoogleFonts.inter(
                  fontSize: 13.5, color: c.textDim, height: 1.55),
              border: InputBorder.none,
              isCollapsed: true,
              counterText: '',
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              'background_extra.chars_counter'.tr(namedArgs: {'current': '${ctrl.text.length}', 'max': '$_maxChars'}),
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
            ),
            const Spacer(),
            if (dirty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: c.orange.withValues(alpha: 0.3)),
                ),
                child: Text('background_extra.unsaved_badge'.tr(),
                    style: GoogleFonts.firaCode(
                        fontSize: 9,
                        color: c.orange,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ),
            _SaveBtn(
              loading: saving,
              enabled: dirty && !saving,
              onTap: onSave,
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Metadata section ─────────────────────────────────────────────────────

class _MetadataSection extends StatelessWidget {
  final List<_MetadataEntry> entries;
  final bool dirty;
  final bool saving;
  final VoidCallback onChanged;
  final VoidCallback onAdd;
  final void Function(int) onRemove;
  final VoidCallback onSave;

  const _MetadataSection({
    required this.entries,
    required this.dirty,
    required this.saving,
    required this.onChanged,
    required this.onAdd,
    required this.onRemove,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
            label: 'background_extra.preferences_label'.tr(),
            hint: 'background_extra.preferences_hint'.tr()),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++)
                _MetadataRow(
                  entry: entries[i],
                  onChanged: onChanged,
                  onRemove: () => onRemove(i),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: _AddBtn(label: 'background_extra.add_preference'.tr(), onTap: onAdd),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              'background_extra.preference_count'.tr(namedArgs: {'n': '${entries.where((e) => e.key.trim().isNotEmpty).length}'}),
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
            ),
            const Spacer(),
            if (dirty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: c.orange.withValues(alpha: 0.3)),
                ),
                child: Text('background_extra.unsaved_badge'.tr(),
                    style: GoogleFonts.firaCode(
                        fontSize: 9,
                        color: c.orange,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ),
            _SaveBtn(
              loading: saving,
              enabled: dirty && !saving,
              onTap: onSave,
            ),
          ],
        ),
      ],
    );
  }
}

class _MetadataRow extends StatefulWidget {
  final _MetadataEntry entry;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  const _MetadataRow({
    required this.entry,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_MetadataRow> createState() => _MetadataRowState();
}

class _MetadataRowState extends State<_MetadataRow> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _valCtrl;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController(text: widget.entry.key);
    _valCtrl = TextEditingController(text: widget.entry.value);
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _valCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: _row(
              c,
              _keyCtrl,
              hint: 'background_extra.key_hint'.tr(),
              monospace: true,
              onChanged: (v) {
                widget.entry.key = v;
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _row(
              c,
              _valCtrl,
              hint: 'background_extra.value_hint'.tr(),
              monospace: false,
              onChanged: (v) {
                widget.entry.value = v;
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'background_extra.remove'.tr(),
            icon: Icon(Icons.close_rounded, size: 14, color: c.textMuted),
            onPressed: widget.onRemove,
          ),
        ],
      ),
    );
  }

  Widget _row(
    AppColors c,
    TextEditingController ctrl, {
    required String hint,
    required bool monospace,
    required ValueChanged<String> onChanged,
  }) {
    final style = monospace
        ? GoogleFonts.firaCode(fontSize: 12, color: c.text)
        : GoogleFonts.inter(fontSize: 12.5, color: c.text);
    return TextField(
      controller: ctrl,
      style: style,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: c.bg,
        hintText: hint,
        hintStyle: monospace
            ? GoogleFonts.firaCode(fontSize: 12, color: c.textDim)
            : GoogleFonts.inter(fontSize: 12.5, color: c.textDim),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c.blue),
        ),
      ),
    );
  }
}

// ─── Attachments section ──────────────────────────────────────────────────

class _AttachmentsSection extends StatelessWidget {
  final List<PayloadFile> files;
  final bool dropZoneActive;
  final bool uploading;
  final String? uploadingFilename;
  final double uploadProgress;
  final VoidCallback onPick;
  final void Function(PayloadFile) onDelete;
  final VoidCallback onDropZoneEnter;
  final VoidCallback onDropZoneExit;
  final void Function(List<XFile>) onFilesDropped;

  const _AttachmentsSection({
    required this.files,
    required this.dropZoneActive,
    required this.uploading,
    required this.uploadingFilename,
    required this.uploadProgress,
    required this.onPick,
    required this.onDelete,
    required this.onDropZoneEnter,
    required this.onDropZoneExit,
    required this.onFilesDropped,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
            label: 'background_extra.attachments_label'.tr(),
            hint: 'background_extra.attachments_hint'.tr()),
        const SizedBox(height: 12),
        if (files.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < files.length; i++) ...[
                  _FileRow(file: files[i], onDelete: () => onDelete(files[i])),
                  if (i < files.length - 1)
                    Divider(height: 1, color: c.border, indent: 14, endIndent: 14),
                ],
              ],
            ),
          ),
        if (files.isNotEmpty) const SizedBox(height: 12),
        DropTarget(
          onDragEntered: (_) => onDropZoneEnter(),
          onDragExited: (_) => onDropZoneExit(),
          onDragDone: (detail) => onFilesDropped(detail.files),
          child: _DropZone(
            active: dropZoneActive,
            uploading: uploading,
            uploadingFilename: uploadingFilename,
            uploadProgress: uploadProgress,
            onTap: onPick,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'background_extra.max_file_size'.tr(),
          style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
        ),
      ],
    );
  }
}

class _FileRow extends StatefulWidget {
  final PayloadFile file;
  final VoidCallback onDelete;
  const _FileRow({required this.file, required this.onDelete});

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = widget.file;
    final (icon, tint) = _iconForCategory(c, f.category);
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: Container(
        color: _h ? c.surfaceAlt.withValues(alpha: 0.4) : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: tint.withValues(alpha: 0.3)),
              ),
              child: Icon(icon, size: 14, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: c.textBright,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${f.sizeDisplay} · ${f.mimeType}',
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'background_extra.remove'.tr(),
              icon: Icon(Icons.close_rounded,
                  size: 15, color: _h ? c.red : c.textMuted),
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
    );
  }

  static (IconData, Color) _iconForCategory(AppColors c, String category) {
    return switch (category) {
      'image' => (Icons.image_outlined, c.cyan),
      'pdf' => (Icons.picture_as_pdf_rounded, c.red),
      'json' => (Icons.data_object_rounded, c.orange),
      'yaml' => (Icons.integration_instructions_outlined, c.purple),
      'csv' => (Icons.table_chart_outlined, c.green),
      'text' => (Icons.description_outlined, c.blue),
      'zip' => (Icons.archive_outlined, c.textMuted),
      _ => (Icons.insert_drive_file_outlined, c.textMuted),
    };
  }
}

class _DropZone extends StatelessWidget {
  final bool active;
  final bool uploading;
  final String? uploadingFilename;
  final double uploadProgress;
  final VoidCallback onTap;

  const _DropZone({
    required this.active,
    required this.uploading,
    required this.uploadingFilename,
    required this.uploadProgress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final borderColor = active
        ? c.blue
        : uploading
            ? c.orange.withValues(alpha: 0.6)
            : c.border;
    final bg = active
        ? c.blue.withValues(alpha: 0.08)
        : c.surface.withValues(alpha: 0.5);

    return MouseRegion(
      cursor: uploading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: uploading ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor,
              width: active ? 1.6 : 1,
              style: BorderStyle.solid,
            ),
          ),
          child: uploading
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.4, color: c.orange),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'background_extra.uploading'.tr(namedArgs: {'name': uploadingFilename ?? '...'}),
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: c.text,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: 240,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: uploadProgress > 0 ? uploadProgress : null,
                          minHeight: 4,
                          backgroundColor: c.border,
                          valueColor: AlwaysStoppedAnimation(c.orange),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      active
                          ? Icons.file_download_rounded
                          : Icons.cloud_upload_outlined,
                      size: 26,
                      color: active ? c.blue : c.textMuted,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      active
                          ? 'background_extra.drop_files_upload'.tr()
                          : 'background_extra.drop_or_click'.tr(),
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: active ? c.blue : c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'background_extra.supported_formats'.tr(),
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textDim),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ─── Shared widgets ───────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String label;
  final String hint;
  const _SectionTitle({required this.label, required this.hint});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: c.textBright,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Container(height: 1, color: c.border)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          style: GoogleFonts.inter(
              fontSize: 11.5, color: c.textMuted, height: 1.4),
        ),
      ],
    );
  }
}

class _SaveBtn extends StatefulWidget {
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;
  const _SaveBtn({
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_SaveBtn> createState() => _SaveBtnState();
}

class _SaveBtnState extends State<_SaveBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.enabled;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: enabled
                ? (_h ? c.blue : c.blue.withValues(alpha: 0.85))
                : c.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: enabled
                  ? c.blue.withValues(alpha: 0.4)
                  : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.loading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.4, color: Colors.white),
                )
              else
                Icon(Icons.save_rounded,
                    size: 13,
                    color: enabled ? Colors.white : c.textDim),
              const SizedBox(width: 6),
              Text(
                'background_extra.save_short'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: enabled ? Colors.white : c.textDim,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _AddBtn({required this.label, required this.onTap});

  @override
  State<_AddBtn> createState() => _AddBtnState();
}

class _AddBtnState extends State<_AddBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _h
                ? c.blue.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: _h
                    ? c.blue.withValues(alpha: 0.4)
                    : c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded,
                  size: 13, color: _h ? c.blue : c.textMuted),
              const SizedBox(width: 4),
              Text(widget.label,
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: _h ? c.blue : c.textMuted,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool loading;
  final VoidCallback? onTap;
  const _ToolbarBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.loading,
    required this.onTap,
  });

  @override
  State<_ToolbarBtn> createState() => _ToolbarBtnState();
}

class _ToolbarBtnState extends State<_ToolbarBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.onTap != null && !widget.loading;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: enabled && _h
                ? widget.color.withValues(alpha: 0.18)
                : widget.color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: widget.color
                    .withValues(alpha: enabled && _h ? 0.5 : 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.loading)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.2, color: widget.color),
                )
              else
                Icon(widget.icon,
                    size: 13,
                    color: enabled ? widget.color : c.textDim),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: enabled ? widget.color : c.textDim,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
