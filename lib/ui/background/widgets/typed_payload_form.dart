import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/background_app_service.dart';
import '../../../theme/app_theme.dart';

/// Renders a full declarative [PayloadSchema] as a typed form:
/// prompt (with min/max length constraints) + metadata fields of the
/// exact right shape per type + file slots matched-by-mime to the
/// current files list + an Activate button gated by the server-side
/// validation block.
///
/// Mutations are delegated back to the parent via the callbacks so
/// the page owning the [SessionPayload] can keep one source of truth
/// (no dual state); this widget is effectively a pure renderer over
/// the schema + payload + validation tuple.
class TypedPayloadForm extends StatefulWidget {
  final PayloadSchema schema;
  final SessionPayload payload;

  /// Mutation callbacks — parent performs the HTTP calls and pushes
  /// the updated [payload] back.
  final Future<void> Function(String prompt) onSavePrompt;
  final Future<void> Function(Map<String, dynamic> metadata) onSaveMetadata;
  final Future<void> Function({
    required Uint8List bytes,
    required String filename,
    String? contentType,
    void Function(int sent, int total)? onProgress,
  }) onUploadFile;
  final Future<void> Function(PayloadFile file) onDeleteFile;
  final Future<void> Function()? onActivate;

  /// True while any mutation is in flight — used to grey out inputs
  /// during an upload or a save.
  final bool busy;

  /// True while the Activate button is being processed.
  final bool activating;

  const TypedPayloadForm({
    super.key,
    required this.schema,
    required this.payload,
    required this.onSavePrompt,
    required this.onSaveMetadata,
    required this.onUploadFile,
    required this.onDeleteFile,
    this.onActivate,
    this.busy = false,
    this.activating = false,
  });

  @override
  State<TypedPayloadForm> createState() => _TypedPayloadFormState();
}

class _TypedPayloadFormState extends State<TypedPayloadForm> {
  // ── Prompt state ─────────────────────────────────────────────────────
  late final TextEditingController _promptCtrl;
  bool _promptDirty = false;
  bool _savingPrompt = false;

  // ── Metadata state ───────────────────────────────────────────────────
  /// Mutable working copy keyed by field name. Kept in sync with the
  /// remote payload whenever the widget receives a new [payload].
  late Map<String, dynamic> _metaValues;
  bool _metaDirty = false;
  bool _savingMeta = false;

  // ── File upload state ────────────────────────────────────────────────
  bool _uploading = false;
  String? _uploadingFilename;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    _promptCtrl = TextEditingController(
      text: widget.payload.prompt.isEmpty
          ? (widget.schema.prompt?.defaultValue ?? '')
          : widget.payload.prompt,
    );
    _promptCtrl.addListener(_onPromptChanged);
    _metaValues = _initMeta();
  }

  @override
  void didUpdateWidget(TypedPayloadForm old) {
    super.didUpdateWidget(old);
    if (old.payload != widget.payload) {
      // Remote payload changed (a save round-trip finished) — reset
      // local dirty state to match.
      final newPrompt = widget.payload.prompt.isEmpty
          ? (widget.schema.prompt?.defaultValue ?? '')
          : widget.payload.prompt;
      if (_promptCtrl.text != newPrompt) {
        _promptCtrl.text = newPrompt;
      }
      _metaValues = _initMeta();
      _metaDirty = false;
      _promptDirty = false;
    }
  }

  @override
  void dispose() {
    _promptCtrl.removeListener(_onPromptChanged);
    _promptCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _initMeta() {
    final out = <String, dynamic>{};
    for (final f in widget.schema.metadata) {
      final remote = widget.payload.metadata[f.name];
      out[f.name] = remote ?? f.defaultValue;
    }
    return out;
  }

  void _onPromptChanged() {
    final dirty = _promptCtrl.text != widget.payload.prompt;
    if (dirty != _promptDirty) {
      setState(() => _promptDirty = dirty);
    } else if (dirty) {
      // Keep the char counter fresh even if dirty state didn't flip.
      setState(() {});
    }
  }

  // ── Prompt save ──────────────────────────────────────────────────────

  Future<void> _savePrompt() async {
    setState(() => _savingPrompt = true);
    await widget.onSavePrompt(_promptCtrl.text);
    if (!mounted) return;
    setState(() {
      _savingPrompt = false;
      _promptDirty = false;
    });
  }

  // ── Metadata save ────────────────────────────────────────────────────

  Future<void> _saveMetadata() async {
    setState(() => _savingMeta = true);
    // Coerce each value through its schema field so the server gets
    // typed values, not raw strings.
    final toSend = <String, dynamic>{};
    for (final field in widget.schema.metadata) {
      final v = field.coerce(_metaValues[field.name]);
      if (v != null) toSend[field.name] = v;
    }
    await widget.onSaveMetadata(toSend);
    if (!mounted) return;
    setState(() {
      _savingMeta = false;
      _metaDirty = false;
    });
  }

  // ── File picker ──────────────────────────────────────────────────────

  Future<void> _pickForSlot(FileSlot slot) async {
    final extensions = slot.acceptedExtensions;
    final types = extensions != null
        ? [XTypeGroup(label: slot.label, extensions: extensions)]
        : const <XTypeGroup>[];
    final files = slot.maxCount > 1
        ? await openFiles(acceptedTypeGroups: types)
        : (await openFile(acceptedTypeGroups: types)).let((f) => [?f]);

    if (files.isEmpty) return;
    for (final f in files) {
      await _uploadWithProgress(slot: slot, file: f);
    }
  }

  Future<void> _uploadWithProgress({
    required FileSlot slot,
    required XFile file,
  }) async {
    final bytes = await file.readAsBytes();
    // Client-side size check so we fail fast.
    final maxBytes = (slot.maxSizeMb * 1024 * 1024).round();
    if (bytes.length > maxBytes) {
      _toastErr(
          '${file.name} is too large (max ${slot.maxSizeMb.toStringAsFixed(0)} MB for this slot)');
      return;
    }
    // Mime check — accept client-reported or infer from extension.
    final mime = file.mimeType ?? _inferMime(file.name);
    if (!slot.acceptsMime(mime)) {
      _toastErr(
          '${file.name} has the wrong type for "${slot.label}" (expected ${slot.mime.join(", ")})');
      return;
    }
    setState(() {
      _uploading = true;
      _uploadingFilename = file.name;
      _uploadProgress = 0;
    });
    try {
      await widget.onUploadFile(
        bytes: Uint8List.fromList(bytes),
        filename: file.name,
        contentType: mime,
        onProgress: (sent, total) {
          if (total > 0 && mounted) {
            setState(() => _uploadProgress = sent / total);
          }
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadingFilename = null;
          _uploadProgress = 0;
        });
      }
    }
  }

  void _toastErr(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: context.colors.red.withValues(alpha: 0.9),
      duration: const Duration(seconds: 4),
    ));
  }

  String _inferMime(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return switch (ext) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'json' => 'application/json',
      'txt' => 'text/plain',
      'csv' => 'text/csv',
      'md' => 'text/markdown',
      'yaml' || 'yml' => 'application/yaml',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final schema = widget.schema;
    final validation = widget.payload.validation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Validation errors (server-side) always displayed at the top.
        if (validation.errors.isNotEmpty) ...[
          _ValidationErrorList(errors: validation.errors),
          const SizedBox(height: 20),
        ],

        if (schema.prompt != null) ...[
          _buildPrompt(c, schema.prompt!),
          const SizedBox(height: 28),
        ],

        if (schema.metadata.isNotEmpty) ...[
          _buildMetadata(c),
          const SizedBox(height: 28),
        ],

        if (schema.files.isNotEmpty) ...[
          _buildFileSlots(c),
          const SizedBox(height: 28),
        ],

        // Activate button — surfaced only when schema declares one
        // via the parent callback, gated on validation.
        if (widget.onActivate != null)
          _ActivateBar(
            validation: validation,
            busy: widget.busy,
            activating: widget.activating,
            onActivate: widget.onActivate!,
          ),
      ],
    );
  }

  // ── Prompt section ───────────────────────────────────────────────────

  Widget _buildPrompt(AppColors c, PromptConfig cfg) {
    final text = _promptCtrl.text;
    final error = cfg.validate(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          label: '${cfg.label.toUpperCase()}${cfg.required ? ' *' : ''}',
          hint: cfg.description,
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: error != null && _promptDirty
                  ? c.red.withValues(alpha: 0.6)
                  : c.border,
            ),
          ),
          padding: const EdgeInsets.all(14),
          child: TextField(
            controller: _promptCtrl,
            minLines: 6,
            maxLines: 16,
            maxLength: cfg.maxLength ?? 4000,
            enabled: !_savingPrompt,
            style: GoogleFonts.inter(
                fontSize: 13.5, color: c.text, height: 1.55),
            decoration: InputDecoration(
              hintText: cfg.placeholder.isNotEmpty
                  ? cfg.placeholder
                  : 'Type the prompt the agent will use at every tick…',
              hintStyle: GoogleFonts.inter(
                  fontSize: 13.5, color: c.textDim, height: 1.55),
              border: InputBorder.none,
              isCollapsed: true,
              counterText: '',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              _promptCounterLabel(text, cfg),
              style: GoogleFonts.firaCode(
                fontSize: 10,
                color: error != null ? c.red : c.textDim,
              ),
            ),
            const Spacer(),
            if (_promptDirty && error == null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(3),
                  border:
                      Border.all(color: c.orange.withValues(alpha: 0.3)),
                ),
                child: Text('UNSAVED',
                    style: GoogleFonts.firaCode(
                        fontSize: 9,
                        color: c.orange,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ),
            _SaveBtn(
              loading: _savingPrompt,
              enabled: _promptDirty && error == null && !_savingPrompt,
              onTap: _savePrompt,
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(error,
              style: GoogleFonts.inter(fontSize: 11, color: c.red)),
        ],
      ],
    );
  }

  String _promptCounterLabel(String text, PromptConfig cfg) {
    final len = text.length;
    final max = cfg.maxLength;
    if (max != null) return '$len / $max chars';
    if (cfg.minLength != null) {
      final need = cfg.minLength! - len;
      return need > 0 ? '$len / min ${cfg.minLength}' : '$len chars';
    }
    return '$len chars';
  }

  // ── Metadata section ─────────────────────────────────────────────────

  Widget _buildMetadata(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          label: 'PREFERENCES',
          hint: 'Structured parameters the agent receives with every run',
        ),
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
              for (var i = 0; i < widget.schema.metadata.length; i++) ...[
                _buildMetaField(c, widget.schema.metadata[i]),
                if (i < widget.schema.metadata.length - 1)
                  const SizedBox(height: 14),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '${widget.schema.metadata.length} field(s)',
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
            ),
            const Spacer(),
            if (_metaDirty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(3),
                  border:
                      Border.all(color: c.orange.withValues(alpha: 0.3)),
                ),
                child: Text('UNSAVED',
                    style: GoogleFonts.firaCode(
                        fontSize: 9,
                        color: c.orange,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ),
            _SaveBtn(
              loading: _savingMeta,
              enabled: _metaDirty && !_savingMeta,
              onTap: _saveMetadata,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMetaField(AppColors c, MetadataField field) {
    final value = _metaValues[field.name];
    final error = field.validate(field.coerce(value));
    final labelText =
        '${field.label}${field.required ? ' *' : ''}';

    Widget input;
    switch (field.type) {
      case 'text':
        input = _textField(
          c,
          initial: value?.toString() ?? '',
          placeholder: field.placeholder ?? '',
          multiline: true,
          onChanged: (v) => _updateMeta(field.name, v),
        );
        break;
      case 'integer':
      case 'number':
        input = _textField(
          c,
          initial: value?.toString() ?? '',
          placeholder: field.placeholder ??
              _numberPlaceholder(field),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (v) => _updateMeta(field.name, v),
        );
        break;
      case 'boolean':
        input = _BooleanField(
          value: value == true,
          label: labelText,
          onChanged: (v) => _updateMeta(field.name, v),
        );
        break;
      case 'select':
        input = _SelectField(
          value: value?.toString(),
          options: field.options,
          label: labelText,
          onChanged: (v) => _updateMeta(field.name, v),
        );
        break;
      case 'string':
      default:
        input = _textField(
          c,
          initial: value?.toString() ?? '',
          placeholder: field.placeholder ?? '',
          onChanged: (v) => _updateMeta(field.name, v),
        );
    }

    // Boolean & select already include their own label → don't stack.
    if (field.type == 'boolean' || field.type == 'select') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          input,
          if (field.description != null) ...[
            const SizedBox(height: 4),
            Text(
              field.description!,
              style: GoogleFonts.inter(fontSize: 11, color: c.textDim),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(error,
                style: GoogleFonts.inter(fontSize: 11, color: c.red)),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(labelText,
            style: GoogleFonts.inter(
                fontSize: 11.5,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        input,
        if (field.description != null) ...[
          const SizedBox(height: 4),
          Text(
            field.description!,
            style: GoogleFonts.inter(fontSize: 11, color: c.textDim),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(error,
              style: GoogleFonts.inter(fontSize: 11, color: c.red)),
        ],
      ],
    );
  }

  String _numberPlaceholder(MetadataField f) {
    final parts = <String>[];
    if (f.min != null) parts.add('min ${f.min}');
    if (f.max != null) parts.add('max ${f.max}');
    return parts.isEmpty ? '' : parts.join(' · ');
  }

  void _updateMeta(String key, dynamic value) {
    setState(() {
      _metaValues[key] = value;
      _metaDirty = true;
    });
  }

  Widget _textField(
    AppColors c, {
    required String initial,
    required String placeholder,
    required ValueChanged<String> onChanged,
    bool multiline = false,
    TextInputType? keyboardType,
  }) {
    return TextFormField(
      initialValue: initial,
      minLines: multiline ? 4 : 1,
      maxLines: multiline ? 8 : 1,
      onChanged: onChanged,
      keyboardType: keyboardType ??
          (multiline ? TextInputType.multiline : TextInputType.text),
      style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: c.bg,
        hintText: placeholder,
        hintStyle: GoogleFonts.firaCode(fontSize: 12, color: c.textDim),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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

  // ── File slots ───────────────────────────────────────────────────────

  Widget _buildFileSlots(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(
          label: 'ATTACHMENTS',
          hint: 'Files re-injected into every activation',
        ),
        const SizedBox(height: 12),
        for (final slot in widget.schema.files) ...[
          _FileSlotWidget(
            slot: slot,
            filesForSlot:
                widget.payload.files.where((f) => slot.acceptsMime(f.mimeType)).toList(),
            uploading: _uploading &&
                (_uploadingFilename == null ||
                    slot.acceptsMime(_inferMime(_uploadingFilename!))),
            uploadingFilename: _uploadingFilename,
            uploadProgress: _uploadProgress,
            onPick: () => _pickForSlot(slot),
            onDelete: widget.onDeleteFile,
            onDropped: (xfiles) async {
              for (final f in xfiles) {
                await _uploadWithProgress(slot: slot, file: f);
              }
            },
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

// ─── Boolean switch field ─────────────────────────────────────────────────

class _BooleanField extends StatelessWidget {
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;
  const _BooleanField({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: GoogleFonts.inter(
                    fontSize: 12.5,
                    color: c.textBright,
                    fontWeight: FontWeight.w600)),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: c.blue,
          ),
        ],
      ),
    );
  }
}

// ─── Select dropdown field ────────────────────────────────────────────────

class _SelectField extends StatelessWidget {
  final String? value;
  final List<String> options;
  final String label;
  final ValueChanged<String?> onChanged;
  const _SelectField({
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11.5,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value != null && options.contains(value) ? value : null,
              hint: Text('Select...',
                  style: GoogleFonts.firaCode(
                      fontSize: 12, color: c.textDim)),
              isExpanded: true,
              dropdownColor: c.surface,
              iconEnabledColor: c.textMuted,
              style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
              items: [
                for (final o in options)
                  DropdownMenuItem(value: o, child: Text(o)),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── File slot widget ─────────────────────────────────────────────────────

class _FileSlotWidget extends StatefulWidget {
  final FileSlot slot;
  final List<PayloadFile> filesForSlot;
  final bool uploading;
  final String? uploadingFilename;
  final double uploadProgress;
  final VoidCallback onPick;
  final Future<void> Function(PayloadFile) onDelete;
  final Future<void> Function(List<XFile>) onDropped;

  const _FileSlotWidget({
    required this.slot,
    required this.filesForSlot,
    required this.uploading,
    required this.uploadingFilename,
    required this.uploadProgress,
    required this.onPick,
    required this.onDelete,
    required this.onDropped,
  });

  @override
  State<_FileSlotWidget> createState() => _FileSlotWidgetState();
}

class _FileSlotWidgetState extends State<_FileSlotWidget> {
  bool _dropActive = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final slot = widget.slot;
    final isFull = widget.filesForSlot.length >= slot.maxCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${slot.label}${slot.required ? ' *' : ''}',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: c.textBright,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            _MimeChip(mime: slot.mime),
            const Spacer(),
            Text(
              '${widget.filesForSlot.length} / ${slot.maxCount}',
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
            ),
          ],
        ),
        if (slot.description != null) ...[
          const SizedBox(height: 4),
          Text(slot.description!,
              style: GoogleFonts.inter(fontSize: 11, color: c.textDim)),
        ],
        const SizedBox(height: 10),
        if (widget.filesForSlot.isNotEmpty) ...[
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < widget.filesForSlot.length; i++) ...[
                  _FileRow(
                    file: widget.filesForSlot[i],
                    onDelete: () => widget.onDelete(widget.filesForSlot[i]),
                  ),
                  if (i < widget.filesForSlot.length - 1)
                    Divider(height: 1, color: c.border, indent: 14, endIndent: 14),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (!isFull)
          DropTarget(
            onDragEntered: (_) => setState(() => _dropActive = true),
            onDragExited: (_) => setState(() => _dropActive = false),
            onDragDone: (detail) async {
              setState(() => _dropActive = false);
              await widget.onDropped(detail.files);
            },
            child: _buildDropZone(c),
          )
        else
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline_rounded,
                    size: 14, color: c.green),
                const SizedBox(width: 8),
                Text(
                  'Slot full (max ${slot.maxCount} file(s))',
                  style: GoogleFonts.inter(
                      fontSize: 11, color: c.textMuted),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDropZone(AppColors c) {
    final slot = widget.slot;
    final uploading = widget.uploading;
    return MouseRegion(
      cursor: uploading ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: uploading ? null : widget.onPick,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: _dropActive
                ? c.blue.withValues(alpha: 0.08)
                : c.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _dropActive
                  ? c.blue
                  : (uploading ? c.orange.withValues(alpha: 0.6) : c.border),
              width: _dropActive ? 1.6 : 1,
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
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.4, color: c.orange),
                        ),
                        const SizedBox(width: 8),
                        Text('Uploading ${widget.uploadingFilename ?? ''}',
                            style: GoogleFonts.inter(
                                fontSize: 11, color: c.text)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 220,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: widget.uploadProgress > 0
                              ? widget.uploadProgress
                              : null,
                          minHeight: 3,
                          backgroundColor: c.border,
                          valueColor: AlwaysStoppedAnimation(c.orange),
                        ),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Icon(
                      _dropActive
                          ? Icons.file_download_rounded
                          : Icons.cloud_upload_outlined,
                      size: 22,
                      color: _dropActive ? c.blue : c.textMuted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _dropActive
                                ? 'Drop to upload'
                                : 'Drop files here, or click to browse',
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: _dropActive ? c.blue : c.text,
                                fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Max ${slot.maxSizeMb.toStringAsFixed(0)} MB · ${slot.mime.isEmpty ? "any type" : slot.mime.join(", ")}',
                            style: GoogleFonts.firaCode(
                                fontSize: 10, color: c.textDim),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ─── Small bits ───────────────────────────────────────────────────────────

class _MimeChip extends StatelessWidget {
  final List<String> mime;
  const _MimeChip({required this.mime});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = mime.isEmpty ? 'ANY' : mime.join(', ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 9,
          color: c.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _FileRow extends StatefulWidget {
  final PayloadFile file;
  final Future<void> Function() onDelete;
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
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: Container(
        color: _h ? c.surfaceAlt.withValues(alpha: 0.4) : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.blue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: c.blue.withValues(alpha: 0.3)),
              ),
              child: Icon(_iconForCategory(f.category), size: 13, color: c.blue),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 12.5,
                          color: c.textBright,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('${f.sizeDisplay} · ${f.mimeType}',
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.close_rounded,
                  size: 14, color: _h ? c.red : c.textMuted),
              onPressed: () => widget.onDelete(),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconForCategory(String category) => switch (category) {
        'image' => Icons.image_outlined,
        'pdf' => Icons.picture_as_pdf_rounded,
        'json' => Icons.data_object_rounded,
        'yaml' => Icons.integration_instructions_outlined,
        'csv' => Icons.table_chart_outlined,
        'text' => Icons.description_outlined,
        'zip' => Icons.archive_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
}

// ─── Validation error list ───────────────────────────────────────────────

class _ValidationErrorList extends StatelessWidget {
  final List<String> errors;
  const _ValidationErrorList({required this.errors});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.red.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.red.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.red),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Validation errors',
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                for (final e in errors) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('• ',
                          style: GoogleFonts.firaCode(
                              fontSize: 11, color: c.red)),
                      Expanded(
                        child: Text(
                          e,
                          style: GoogleFonts.firaCode(
                              fontSize: 11, color: c.red, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy errors',
            icon: Icon(Icons.copy_rounded, size: 14, color: c.textMuted),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: errors.join('\n')));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Errors copied'),
                duration: Duration(seconds: 2),
              ));
            },
          ),
        ],
      ),
    );
  }
}

// ─── Activate button bar ─────────────────────────────────────────────────

class _ActivateBar extends StatelessWidget {
  final PayloadValidation validation;
  final bool busy;
  final bool activating;
  final Future<void> Function() onActivate;
  const _ActivateBar({
    required this.validation,
    required this.busy,
    required this.activating,
    required this.onActivate,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final blocked = validation.blocksActivation;
    final enabled = !blocked && !busy && !activating;
    final label = activating ? 'Activating…' : 'Activate session';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(
            blocked
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 18,
            color: blocked ? c.orange : c.green,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              blocked
                  ? 'Fill the required fields above to activate this session'
                  : 'Ready to activate — every trigger will reuse this payload',
              style: GoogleFonts.inter(
                  fontSize: 11.5, color: c.text, height: 1.45),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: enabled ? () => onActivate() : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: c.blue,
              disabledBackgroundColor: c.surfaceAlt,
              foregroundColor: Colors.white,
              disabledForegroundColor: c.textDim,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (activating) ...[
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                ] else ...[
                  const Icon(Icons.play_arrow_rounded, size: 16),
                  const SizedBox(width: 4),
                ],
                Text(label,
                    style: GoogleFonts.inter(
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shared UI bits mirrored from the generic page ────────────────────────

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
        if (hint.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            hint,
            style: GoogleFonts.inter(
                fontSize: 11.5, color: c.textMuted, height: 1.4),
          ),
        ],
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: enabled
                ? (_h ? c.blue : c.blue.withValues(alpha: 0.85))
                : c.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: enabled ? c.blue.withValues(alpha: 0.4) : c.border),
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
              Text('Save',
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: enabled ? Colors.white : c.textDim,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Let helper ──────────────────────────────────────────────────────────

extension _LetExt<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
