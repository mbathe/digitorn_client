/// Digitorn Widgets v1 — input primitives.
///
/// form, text_input, textarea, select, multi_select, radio,
/// checkbox, switch, slider, date/time/datetime, file_upload,
/// code_editor.
library;

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/auth_service.dart';

import '../../theme/app_theme.dart';
import '../bindings.dart';
import '../models.dart';
import '../runtime.dart';
import 'layout.dart' show widgetIconByName;

Widget _build(WidgetNode n, WidgetRuntime r, Map<String, dynamic>? s) =>
    buildNode(n, r, scopeExtra: s);

// ─── form ─────────────────────────────────────────────────────────

Widget buildForm(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _FormStateful(node: node, runtime: runtime, extra: extra);
}

class _FormStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _FormStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_FormStateful> createState() => _FormStatefulState();
}

class _FormStatefulState extends State<_FormStateful> {
  late final String _formId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _formId = widget.node.id ??
        'form_${widget.node.props.hashCode.toRadixString(16)}';
    final initialRaw = widget.node.props['initial'];
    final initial = initialRaw is Map
        ? initialRaw.cast<String, dynamic>()
        : const <String, dynamic>{};
    widget.runtime.state.pushForm(_formId, initial);
  }

  @override
  void dispose() {
    widget.runtime.state.popForm(_formId);
    super.dispose();
  }

  Future<void> _submit() async {
    final submit = widget.node.nodeAt('submit') ??
        (widget.node.props['submit'] is Map
            ? WidgetNode(
                type: 'button',
                props: (widget.node.props['submit'] as Map)
                    .cast<String, dynamic>(),
              )
            : null);
    if (submit == null) return;
    final action = submit.actionAt('action');
    if (action == null) return;
    setState(() => _busy = true);
    try {
      final r = await widget.runtime.dispatcher.run(
        action,
        context: context,
        scopeExtra: widget.extra,
      );
      if (!mounted) return;
      if (r.ok) {
        final onSuccess = widget.node.actionAt('on_success');
        if (onSuccess != null) {
          await widget.runtime.dispatcher.run(
            onSuccess,
            context: context,
            scopeExtra: widget.extra,
          );
        }
      } else {
        final onError = widget.node.actionAt('on_error');
        if (onError != null) {
          await widget.runtime.dispatcher.run(
            onError,
            context: context,
            scopeExtra: {...?widget.extra, 'error': {'message': r.error}},
          );
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Form frame is owned by initState (pushForm) and released in
    // dispose (popForm). Never re-push during build — doing so
    // clobbers `_activeForm` and breaks nested forms whose parent
    // rebuilds while the child is still mounted.
    final children = widget.node.children ?? const [];
    final submitRaw = widget.node.props['submit'];
    Map<String, dynamic>? submitMap;
    if (submitRaw is Map) {
      submitMap = submitRaw.cast<String, dynamic>();
    }

    return AnimatedBuilder(
      animation: widget.runtime.state,
      builder: (_, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _build(child, widget.runtime, widget.extra),
              ),
            if (submitMap != null) ...[
              const SizedBox(height: 4),
              _submitBar(c, submitMap),
            ],
          ],
        );
      },
    );
  }

  Widget _submitBar(AppColors c, Map<String, dynamic> submit) {
    final label = _busy
        ? (submit['loading_label']?.toString() ?? 'Working…')
        : submit['label']?.toString() ?? 'Submit';
    final iconName = submit['icon']?.toString();
    final disabledExpr = submit['disabled']?.toString();
    final scope = widget.runtime.state.buildScope(extra: widget.extra);
    final disabled = disabledExpr != null
        ? evalBool(disabledExpr, scope)
        : false;
    return Row(
      children: [
        const Spacer(),
        ElevatedButton.icon(
          onPressed: (_busy || disabled) ? null : _submit,
          icon: _busy
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  iconName != null
                      ? widgetIconByName(iconName)
                      : Icons.check_rounded,
                  size: 14,
                  color: Colors.white,
                ),
          label: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.runtime.accentColor(widget.node, c),
            elevation: 0,
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── text_input ───────────────────────────────────────────────────

Widget buildTextInput(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _TextInputStateful(node: node, runtime: runtime, extra: extra);
}

class _TextInputStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _TextInputStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_TextInputStateful> createState() => _TextInputStatefulState();
}

class _TextInputStatefulState extends State<_TextInputStateful> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    final name = widget.node.props['name']?.toString() ?? '';
    final existing = widget.runtime.state.getField(name);
    _ctrl = TextEditingController(text: existing?.toString() ?? '');
    // Run validation once at mount so `form.valid` correctly
    // reflects required-but-empty fields before the user touches
    // anything. Deferred to post-frame so we don't notify during
    // the parent's build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runValidation(_ctrl.text);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.node;
    final name = n.props['name']?.toString() ?? '';
    final label = n.props['label']?.toString() ?? '';
    final placeholder = n.props['placeholder']?.toString() ?? '';
    final typeHint = n.props['type_hint']?.toString() ?? 'text';
    final help = n.props['help']?.toString();
    final prefixIcon = n.props['prefix_icon']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: c.textBright,
            ),
          ),
          const SizedBox(height: 5),
        ],
        TextField(
          controller: _ctrl,
          obscureText: typeHint == 'password',
          keyboardType: _keyboardType(typeHint),
          style: GoogleFonts.inter(fontSize: 13, color: c.text),
          onChanged: (v) {
            widget.runtime.state.setField(name, v);
            _runValidation(v);
          },
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: c.surfaceAlt,
            hintText: placeholder,
            hintStyle: GoogleFonts.inter(fontSize: 13, color: c.textDim),
            prefixIcon: prefixIcon != null
                ? Icon(widgetIconByName(prefixIcon),
                    size: 15, color: c.textMuted)
                : null,
            prefixIconConstraints: const BoxConstraints(
              minWidth: 34,
              minHeight: 20,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: c.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: c.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(
                color: widget.runtime.accentColor(widget.node, c),
              ),
            ),
          ),
        ),
        if (help != null && help.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              help,
              style: GoogleFonts.inter(fontSize: 10.5, color: c.textMuted),
            ),
          ),
      ],
    );
  }

  void _runValidation(String v) {
    final n = widget.node;
    final name = n.props['name']?.toString() ?? '';
    final required = n.props['required'] == true;
    final valRaw = n.props['validation'];
    if (required && v.isEmpty) {
      widget.runtime.state.setFieldError(name, 'Required');
      return;
    }
    if (valRaw is Map) {
      final val = valRaw.cast<String, dynamic>();
      final regex = val['regex']?.toString();
      final min = asInt(val['min']);
      final max = asInt(val['max']);
      final message = val['message']?.toString() ?? 'Invalid';
      if (min != null && v.length < min) {
        widget.runtime.state.setFieldError(name, message);
        return;
      }
      if (max != null && v.length > max) {
        widget.runtime.state.setFieldError(name, message);
        return;
      }
      if (regex != null && regex.isNotEmpty) {
        try {
          if (!RegExp(regex).hasMatch(v)) {
            widget.runtime.state.setFieldError(name, message);
            return;
          }
        } catch (_) {}
      }
    }
    widget.runtime.state.setFieldError(name, '');
  }

  TextInputType _keyboardType(String hint) {
    switch (hint) {
      case 'email':
        return TextInputType.emailAddress;
      case 'url':
        return TextInputType.url;
      case 'number':
        return TextInputType.number;
      case 'tel':
        return TextInputType.phone;
      default:
        return TextInputType.text;
    }
  }
}

// ─── textarea ─────────────────────────────────────────────────────

Widget buildTextarea(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _TextareaStateful(node: node, runtime: runtime, extra: extra);
}

class _TextareaStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _TextareaStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_TextareaStateful> createState() => _TextareaStatefulState();
}

class _TextareaStatefulState extends State<_TextareaStateful> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    final name = widget.node.props['name']?.toString() ?? '';
    final existing = widget.runtime.state.getField(name);
    _ctrl = TextEditingController(text: existing?.toString() ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.node;
    final name = n.props['name']?.toString() ?? '';
    final label = n.props['label']?.toString() ?? '';
    final rows = asInt(n.props['rows']) ?? 3;
    final maxChars = asInt(n.props['max_chars']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
          const SizedBox(height: 5),
        ],
        TextField(
          controller: _ctrl,
          maxLines: rows,
          minLines: rows,
          maxLength: maxChars,
          style: GoogleFonts.inter(fontSize: 13, color: c.text),
          onChanged: (v) => widget.runtime.state.setField(name, v),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: c.surfaceAlt,
            contentPadding: const EdgeInsets.all(11),
            counterStyle:
                GoogleFonts.inter(fontSize: 10, color: c.textMuted),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: c.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: BorderSide(color: c.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide:
                  BorderSide(color: widget.runtime.accentColor(widget.node, c)),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── select ───────────────────────────────────────────────────────

Widget buildSelect(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final n = node;
    final name = n.props['name']?.toString() ?? '';
    final label = n.props['label']?.toString() ?? '';
    final scope = runtime.state.buildScope(extra: extra);
    final options = _resolveOptions(n, scope);
    final defaultValue = n.props['default'];
    final current = runtime.state.getField(name) ?? defaultValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
          const SizedBox(height: 5),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: c.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: options.any((o) => o.value == current?.toString())
                  ? current?.toString()
                  : null,
              hint: Text('Select…',
                  style:
                      GoogleFonts.inter(fontSize: 12, color: c.textDim)),
              icon: Icon(Icons.keyboard_arrow_down_rounded,
                  size: 16, color: c.textMuted),
              dropdownColor: c.surface,
              style: GoogleFonts.inter(fontSize: 12, color: c.text),
              items: [
                for (final o in options)
                  DropdownMenuItem(
                    value: o.value,
                    child: Text(o.label),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                runtime.state.setField(name, v);
              },
            ),
          ),
        ),
      ],
    );
  });
}

class _Opt {
  final String value;
  final String label;
  const _Opt(this.value, this.label);
}

List<_Opt> _resolveOptions(WidgetNode n, BindingScope scope) {
  final staticOpts = n.props['options'];
  if (staticOpts is List) {
    return staticOpts
        .whereType<Map>()
        .map((m) => _Opt(
              m['value']?.toString() ?? '',
              m['label']?.toString() ?? m['value']?.toString() ?? '',
            ))
        .toList();
  }
  final fromExpr = n.props['options_from'];
  if (fromExpr is String) {
    final items = evalValue(fromExpr, scope);
    if (items is List) {
      final labelExpr = n.props['option_label']?.toString() ?? '{{item.name}}';
      final valueExpr = n.props['option_value']?.toString() ?? '{{item.id}}';
      return items.map((e) {
        final sub = scope.fork({'item': e});
        return _Opt(
          evalTemplate(valueExpr, sub),
          evalTemplate(labelExpr, sub),
        );
      }).toList();
    }
  }
  return const [];
}

// ─── multi_select ─────────────────────────────────────────────────

Widget buildMultiSelect(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final name = node.props['name']?.toString() ?? '';
    final scope = runtime.state.buildScope(extra: extra);
    final options = _resolveOptions(node, scope);
    final current =
        (runtime.state.getField(name) as List?)?.cast<dynamic>() ?? const [];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final o in options)
          FilterChip(
            label: Text(o.label,
                style: GoogleFonts.inter(fontSize: 11.5, color: c.text)),
            selected: current.contains(o.value),
            onSelected: (sel) {
              final next = [...current];
              if (sel) {
                next.add(o.value);
              } else {
                next.remove(o.value);
              }
              runtime.state.setField(name, next);
            },
            backgroundColor: c.surfaceAlt,
            selectedColor: runtime
                .accentColor(node, c)
                .withValues(alpha: 0.15),
            side: BorderSide(color: c.border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
      ],
    );
  });
}

// ─── radio ────────────────────────────────────────────────────────

Widget buildRadio(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final name = node.props['name']?.toString() ?? '';
    final label = node.props['label']?.toString() ?? '';
    final layout = node.props['layout']?.toString() ?? 'vertical';
    final scope = runtime.state.buildScope(extra: extra);
    final options = _resolveOptions(node, scope);
    final current = runtime.state.getField(name);
    final items = [
      for (final o in options)
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => runtime.state.setField(name, o.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  current == o.value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: current == o.value
                      ? runtime.accentColor(node, c)
                      : c.textMuted,
                ),
                const SizedBox(width: 8),
                Text(o.label,
                    style: GoogleFonts.inter(
                        fontSize: 12.5, color: c.text)),
              ],
            ),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
          const SizedBox(height: 6),
        ],
        if (layout == 'horizontal')
          Wrap(spacing: 10, children: items)
        else
          Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: items),
      ],
    );
  });
}

// ─── checkbox ─────────────────────────────────────────────────────

Widget buildCheckbox(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final name = node.props['name']?.toString() ?? '';
    final label = node.props['label']?.toString() ?? '';
    final current = runtime.state.getField(name) == true;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => runtime.state.setField(name, !current),
      child: Row(
        children: [
          Icon(
            current
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            size: 18,
            color: current ? runtime.accentColor(node, c) : c.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: GoogleFonts.inter(fontSize: 12.5, color: c.text)),
          ),
        ],
      ),
    );
  });
}

// ─── switch ───────────────────────────────────────────────────────

Widget buildSwitchNode(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final name = node.props['name']?.toString() ?? '';
    final label = node.props['label']?.toString() ?? '';
    final def = node.props['default'] == true;
    final current = runtime.state.getField(name) ?? def;
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: GoogleFonts.inter(fontSize: 12.5, color: c.text)),
        ),
        Switch(
          value: current == true,
          activeThumbColor: runtime.accentColor(node, c),
          onChanged: (v) => runtime.state.setField(name, v),
        ),
      ],
    );
  });
}

// ─── slider ───────────────────────────────────────────────────────

Widget buildSlider(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final name = node.props['name']?.toString() ?? '';
    final label = node.props['label']?.toString() ?? '';
    final min = asDouble(node.props['min']) ?? 0;
    final max = asDouble(node.props['max']) ?? 1;
    final step = asDouble(node.props['step']) ?? 0.01;
    final def = asDouble(node.props['default']) ?? min;
    final current = (runtime.state.getField(name) as num?)?.toDouble() ?? def;
    final showValue = node.props['show_value'] != false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: c.textBright)),
              ),
              if (showValue)
                Text(current.toStringAsFixed(2),
                    style:
                        GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
            ],
          ),
        Slider(
          value: current.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) / step).round(),
          activeColor: runtime.accentColor(node, c),
          onChanged: (v) => runtime.state.setField(name, v),
        ),
      ],
    );
  });
}

// ─── date / time / datetime ──────────────────────────────────────

Widget buildDate(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return Builder(builder: (ctx) {
    final c = ctx.colors;
    final name = node.props['name']?.toString() ?? '';
    final label = node.props['label']?.toString() ?? '';
    final kind = node.type;
    final current = runtime.state.getField(name)?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
          const SizedBox(height: 5),
        ],
        InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () async {
            if (kind == 'time') {
              final t = await showTimePicker(
                context: ctx,
                initialTime: TimeOfDay.now(),
              );
              if (t != null) {
                runtime.state.setField(name,
                    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
              }
              return;
            }
            final d = await showDatePicker(
              context: ctx,
              initialDate: DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (d != null) {
              runtime.state.setField(name,
                  '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
            }
          },
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(
                  kind == 'time'
                      ? Icons.access_time_rounded
                      : Icons.calendar_today_rounded,
                  size: 14,
                  color: c.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    current.isEmpty ? 'Pick…' : current,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: current.isEmpty ? c.textDim : c.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  });
}

// ─── file_upload ─────────────────────────────────────────────────
//
// Wires file_selector for file picking and (when `upload_to:` is
// declared) an immediate multipart POST via Dio. The form field
// stores a list of {name, size, path, uploaded_url} — consumers
// can pass it straight to a tool/http action.

Widget buildFileUpload(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _FileUploadStateful(node: node, runtime: runtime, extra: extra);
}

class _FileUploadStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _FileUploadStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_FileUploadStateful> createState() => _FileUploadStatefulState();
}

class _FileUploadStatefulState extends State<_FileUploadStateful> {
  List<_PickedFile> _files = const [];
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    final n = widget.node;
    final multiple = n.props['multiple'] == true;
    final accept =
        (n.props['accept'] as List? ?? const []).map((e) => e.toString()).toList();
    final extensions =
        accept.map((e) => e.startsWith('.') ? e.substring(1) : e).toList();
    final maxMb = asDouble(n.props['max_size_mb']) ?? 50;
    final typeGroup = XTypeGroup(
      label: 'files',
      extensions: extensions.isEmpty ? null : extensions,
    );

    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final picked = <XFile>[];
      if (multiple) {
        picked.addAll(await openFiles(acceptedTypeGroups: [typeGroup]));
      } else {
        final one = await openFile(acceptedTypeGroups: [typeGroup]);
        if (one != null) picked.add(one);
      }
      if (picked.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final processed = <_PickedFile>[];
      for (final f in picked) {
        final bytes = await f.readAsBytes();
        final sizeMb = bytes.lengthInBytes / (1024 * 1024);
        if (sizeMb > maxMb) {
          throw '${f.name}: exceeds ${maxMb.toStringAsFixed(0)} MB';
        }
        processed.add(_PickedFile(
          name: f.name,
          size: bytes.lengthInBytes,
          path: f.path,
          bytes: bytes,
        ));
      }
      setState(() => _files = processed);

      // Auto-upload if `upload_to:` is declared. Result URLs are
      // stored alongside the file entry so the form action can read
      // them.
      final uploadTo = n.props['upload_to'];
      if (uploadTo is Map) {
        await _upload(uploadTo.cast<String, dynamic>());
      }

      _writeToForm();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload(Map<String, dynamic> spec) async {
    final urlRaw = spec['url']?.toString() ?? '';
    if (urlRaw.isEmpty) return;
    final field = spec['field']?.toString() ?? 'file';
    final appId = widget.runtime.appId;
    final base = AuthService().baseUrl;
    final full = urlRaw.startsWith('http')
        ? urlRaw
        : '$base/api/apps/$appId${urlRaw.startsWith('/') ? '' : '/'}$urlRaw';

    // Use the auth interceptor so 401 → refresh is handled for us.
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 120),
      sendTimeout: const Duration(seconds: 120),
    ))
      ..interceptors.add(AuthService().authInterceptor);

    try {
      for (final f in _files) {
        try {
          final form = FormData.fromMap({
            field: MultipartFile.fromBytes(
              f.bytes,
              filename: f.name,
            ),
          });
          final resp = await dio.post(full, data: form);
          final body = resp.data;
          if (body is Map) {
            f.uploadedUrl = body['url']?.toString() ??
                (body['data'] is Map
                    ? (body['data'] as Map)['url']?.toString()
                    : null);
            f.uploaded = true;
          }
        } catch (e) {
          f.error = e.toString();
        }
      }
    } finally {
      dio.close(force: true);
    }
    if (mounted) setState(() {});
  }

  void _writeToForm() {
    final name = widget.node.props['name']?.toString() ?? '';
    final list = _files
        .map((f) => {
              'name': f.name,
              'size': f.size,
              'path': f.path,
              if (f.uploadedUrl != null) 'url': f.uploadedUrl,
              if (f.error != null) 'error': f.error,
            })
        .toList();
    widget.runtime.state.setField(name, list);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.node;
    final label = n.props['label']?.toString() ?? 'Attach files';
    final help = n.props['help']?.toString();
    final multiple = n.props['multiple'] == true;
    final accept =
        (n.props['accept'] as List? ?? const []).map((e) => e.toString()).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        const SizedBox(height: 6),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _busy ? null : _pick,
          child: DottedBorderContainer(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.upload_file_rounded,
                      size: 22, color: c.textMuted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _busy
                              ? 'Working…'
                              : _files.isEmpty
                                  ? (multiple
                                      ? 'Click to pick files'
                                      : 'Click to pick a file')
                                  : '${_files.length} file(s) selected',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: c.text,
                          ),
                        ),
                        if (accept.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              accept.join('  '),
                              style: GoogleFonts.firaCode(
                                fontSize: 10,
                                color: c.textMuted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_busy)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: widget.runtime.accentColor(widget.node, c),
                      ),
                    )
                  else
                    Icon(Icons.add_rounded,
                        size: 16, color: c.textMuted),
                ],
              ),
            ),
          ),
        ),
        if (help != null && help.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              help,
              style: GoogleFonts.inter(fontSize: 10.5, color: c.textMuted),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              style: GoogleFonts.inter(fontSize: 11, color: c.red),
            ),
          ),
        if (_files.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final f in _files)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  Icon(
                    f.error != null
                        ? Icons.error_outline_rounded
                        : f.uploaded
                            ? Icons.check_circle_outline_rounded
                            : Icons.insert_drive_file_outlined,
                    size: 14,
                    color: f.error != null
                        ? c.red
                        : f.uploaded
                            ? c.green
                            : c.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f.name,
                      style: GoogleFonts.inter(
                          fontSize: 11.5, color: c.text),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _formatSize(f.size),
                    style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 13, color: c.textMuted),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        _files =
                            _files.where((x) => x != f).toList();
                      });
                      _writeToForm();
                    },
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _PickedFile {
  final String name;
  final int size;
  final String path;
  final Uint8List bytes;
  bool uploaded = false;
  String? uploadedUrl;
  String? error;

  _PickedFile({
    required this.name,
    required this.size,
    required this.path,
    required this.bytes,
  });
}

/// Simple dashed-border container for the drop-target look.
class DottedBorderContainer extends StatelessWidget {
  final Widget child;
  const DottedBorderContainer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _surfaceAlt(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _border(context),
          style: BorderStyle.solid,
          width: 1,
        ),
      ),
      child: child,
    );
  }

  Color _surfaceAlt(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHigh;
  Color _border(BuildContext context) => Theme.of(context).dividerColor;
}

// ─── code_editor (simple monospace textarea) ─────────────────────

Widget buildCodeEditor(
  WidgetNode node,
  WidgetRuntime runtime,
  Map<String, dynamic>? extra,
) {
  return _CodeEditorStateful(node: node, runtime: runtime, extra: extra);
}

class _CodeEditorStateful extends StatefulWidget {
  final WidgetNode node;
  final WidgetRuntime runtime;
  final Map<String, dynamic>? extra;
  const _CodeEditorStateful({
    required this.node,
    required this.runtime,
    this.extra,
  });

  @override
  State<_CodeEditorStateful> createState() => _CodeEditorStatefulState();
}

class _CodeEditorStatefulState extends State<_CodeEditorStateful> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    final name = widget.node.props['name']?.toString() ?? '';
    _ctrl = TextEditingController(
      text: widget.runtime.state.getField(name)?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.node;
    final name = n.props['name']?.toString() ?? '';
    final label = n.props['label']?.toString() ?? '';
    final minLines = asInt(n.props['min_lines']) ?? 4;
    final maxLines = asInt(n.props['max_lines']) ?? 20;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) ...[
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
          const SizedBox(height: 5),
        ],
        Container(
          decoration: BoxDecoration(
            color: c.codeBlockBg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: c.border),
          ),
          child: TextField(
            controller: _ctrl,
            minLines: minLines,
            maxLines: maxLines,
            style: GoogleFonts.firaCode(fontSize: 11.5, color: c.text),
            inputFormatters: [
              // Allow tab indentation
              TextInputFormatter.withFunction((old, v) {
                return v;
              }),
            ],
            onChanged: (v) => widget.runtime.state.setField(name, v),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(12),
            ),
          ),
        ),
      ],
    );
  }
}
