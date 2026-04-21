/// Reusable field-form used by every credential dialog — the
/// create form, the edit dialog, the inline form inside the picker.
/// Renders a list of [ProviderFieldSpec] entries with rich visuals:
///
///   * Per-field icon derived from the field type (key / URL /
///     dropdown / number / flag)
///   * Inline "Where do I find this?" link to the daemon-provided
///     docs URL, rendered as a proper chip
///   * Show/hide toggle for every secret field
///   * Live validation against the daemon's regex + URL parsing
///   * Inline error pills, not just text
///   * Description text below each field as a help line
///   * Visual grouping (required fields first, optional collapsed)
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/credential_v2.dart';
import '../../theme/app_theme.dart';

class CredentialFieldForm extends StatefulWidget {
  final List<ProviderFieldSpec> fields;
  final Map<String, String> initialValues;
  final void Function(Map<String, String> values, bool isValid) onChanged;

  /// When true, optional fields start collapsed behind a "Show
  /// advanced" toggle. Required fields stay visible. Keeps the
  /// create form short for simple providers (OpenAI key) while
  /// still exposing the full spec for complex ones (AWS).
  final bool collapseOptional;

  const CredentialFieldForm({
    super.key,
    required this.fields,
    this.initialValues = const {},
    required this.onChanged,
    this.collapseOptional = true,
  });

  @override
  State<CredentialFieldForm> createState() => CredentialFieldFormState();
}

class CredentialFieldFormState extends State<CredentialFieldForm> {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, bool> _showPlain = {};
  final Map<String, String?> _errors = {};
  bool _showOptional = false;

  List<ProviderFieldSpec> get _required =>
      widget.fields.where((f) => f.required).toList();
  List<ProviderFieldSpec> get _optional =>
      widget.fields.where((f) => !f.required).toList();

  Map<String, String> get values => {
        for (final f in widget.fields)
          if ((_ctrls[f.name]?.text ?? '').isNotEmpty)
            f.name: _ctrls[f.name]!.text,
      };

  bool get isValid {
    for (final f in widget.fields) {
      final v = _ctrls[f.name]?.text ?? '';
      if (f.validate(v) != null) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      _ctrls[f.name] =
          TextEditingController(text: widget.initialValues[f.name] ?? '');
      _ctrls[f.name]!.addListener(_emit);
      _showPlain[f.name] = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  void _emit() {
    final newErrors = <String, String?>{};
    for (final f in widget.fields) {
      final v = _ctrls[f.name]?.text ?? '';
      newErrors[f.name] = v.isEmpty ? null : f.validate(v);
    }
    if (mounted) setState(() => _errors..clear()..addAll(newErrors));
    widget.onChanged(values, isValid);
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasOptional = _optional.isNotEmpty;
    final showOptional = !widget.collapseOptional || _showOptional;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in _required) _buildField(context, f),
        if (hasOptional && widget.collapseOptional) ...[
          const SizedBox(height: 4),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _showOptional = !_showOptional),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _showOptional
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: c.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _showOptional
                        ? 'Hide advanced options'
                        : 'Show ${_optional.length} advanced option${_optional.length == 1 ? '' : 's'}',
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: c.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (showOptional)
          for (final f in _optional) _buildField(context, f),
      ],
    );
  }

  IconData _iconFor(ProviderFieldSpec f) {
    if (f.isSecret) return Icons.key_rounded;
    if (f.isUrl) return Icons.link_rounded;
    if (f.isSelect) return Icons.arrow_drop_down_circle_outlined;
    switch (f.type) {
      case 'int':
        return Icons.numbers_rounded;
      case 'bool':
        return Icons.toggle_on_rounded;
      default:
        return Icons.text_fields_rounded;
    }
  }

  Widget _buildField(BuildContext context, ProviderFieldSpec f) {
    final c = context.colors;
    final err = _errors[f.name];
    final hasValue = (_ctrls[f.name]?.text ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: (err != null ? c.red : c.blue).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color:
                        (err != null ? c.red : c.blue).withValues(alpha: 0.3),
                  ),
                ),
                child: Icon(_iconFor(f),
                    size: 12, color: err != null ? c.red : c.blue),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        f.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: c.textBright,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                    if (f.required) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('REQUIRED',
                            style: GoogleFonts.firaCode(
                                fontSize: 7.5,
                                color: c.red,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4)),
                      ),
                    ],
                  ],
                ),
              ),
              if (f.docsUrl.isNotEmpty)
                InkWell(
                  onTap: () => launchUrl(Uri.parse(f.docsUrl),
                      mode: LaunchMode.externalApplication),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: c.blue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: c.blue.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.help_outline_rounded,
                            size: 10, color: c.blue),
                        const SizedBox(width: 3),
                        Text('Where do I find this?',
                            style: GoogleFonts.inter(
                                fontSize: 9.5,
                                color: c.blue,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (f.isSelect)
            DropdownButtonFormField<String>(
              initialValue: _ctrls[f.name]?.text.isNotEmpty == true
                  ? _ctrls[f.name]!.text
                  : null,
              items: f.options
                  .map((o) => DropdownMenuItem(
                        value: o,
                        child: Text(o,
                            style: GoogleFonts.firaCode(fontSize: 12.5)),
                      ))
                  .toList(),
              onChanged: (v) {
                _ctrls[f.name]?.text = v ?? '';
                _emit();
              },
              decoration:
                  _decoration(c, f.placeholder, hasError: err != null),
              dropdownColor: c.surface,
              style: GoogleFonts.firaCode(fontSize: 12.5, color: c.textBright),
            )
          else
            TextField(
              controller: _ctrls[f.name],
              obscureText: f.isSecret && !(_showPlain[f.name] ?? false),
              autocorrect: !f.isSecret,
              enableSuggestions: !f.isSecret,
              keyboardType: f.type == 'int'
                  ? TextInputType.number
                  : f.isUrl
                      ? TextInputType.url
                      : TextInputType.text,
              style: GoogleFonts.firaCode(
                  fontSize: 12.5, color: c.textBright, height: 1.3),
              decoration: _decoration(
                c,
                f.placeholder,
                hasError: err != null,
                hasValue: hasValue,
                suffix: f.isSecret
                    ? IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 15,
                        tooltip: (_showPlain[f.name] ?? false)
                            ? 'Hide'
                            : 'Reveal',
                        icon: Icon(
                          (_showPlain[f.name] ?? false)
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          color: c.textMuted,
                        ),
                        onPressed: () => setState(() => _showPlain[f.name] =
                            !(_showPlain[f.name] ?? false)),
                      )
                    : null,
              ),
            ),
          if (f.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                f.description,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: c.textMuted,
                  height: 1.45,
                ),
              ),
            ),
          ],
          if (err != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: c.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: c.red.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 11, color: c.red),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(err,
                        style: GoogleFonts.inter(
                            fontSize: 10.5,
                            color: c.red,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _decoration(
    AppColors c,
    String hint, {
    Widget? suffix,
    bool hasError = false,
    bool hasValue = false,
  }) {
    // `c.surface` (the picker card) and `c.surfaceAlt` (the legacy
    // input fill) are only ~3 shades apart on dark theme, so the
    // input blends into the card. Use the black background (`c.bg`)
    // plus a visible `borderHover` outline — the input reads as a
    // distinct "sunken" panel inside the card.
    final borderCol = hasError
        ? c.red
        : hasValue
            ? c.blue.withValues(alpha: 0.6)
            : c.borderHover;
    return InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: GoogleFonts.firaCode(fontSize: 12, color: c.textMuted),
      filled: true,
      fillColor: c.bg,
      suffixIcon: suffix,
      suffixIconConstraints:
          const BoxConstraints(minWidth: 32, minHeight: 32),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: borderCol, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
            color: hasError ? c.red : c.blue, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.red),
      ),
    );
  }
}
