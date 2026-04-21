/// Configuration sheet shown when the user clicks Install on a
/// catalogue entry. Renders one input per `requiredEnv` + optional
/// section for `optionalEnv`, then posts to `McpService.install`.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/mcp_server.dart';
import '../../services/mcp_service.dart';
import '../../theme/app_theme.dart';

class McpInstallDialog {
  static Future<McpServer?> show(
    BuildContext context, {
    required McpCatalogueEntry entry,
  }) {
    return showDialog<McpServer>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _Dialog(entry: entry),
    );
  }
}

class _Dialog extends StatefulWidget {
  final McpCatalogueEntry entry;
  const _Dialog({required this.entry});

  @override
  State<_Dialog> createState() => _DialogState();
}

class _DialogState extends State<_Dialog> {
  final Map<String, TextEditingController> _envCtrls = {};
  final Map<String, bool> _showPlain = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final e in widget.entry.requiredEnv) {
      _envCtrls[e.name] = TextEditingController();
      _showPlain[e.name] = false;
    }
    for (final e in widget.entry.optionalEnv) {
      _envCtrls[e.name] = TextEditingController();
      _showPlain[e.name] = false;
    }
  }

  @override
  void dispose() {
    for (final c in _envCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isValid {
    for (final e in widget.entry.requiredEnv) {
      if ((_envCtrls[e.name]?.text ?? '').isEmpty) return false;
    }
    return true;
  }

  Future<void> _install() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final env = <String, String>{};
      _envCtrls.forEach((k, v) {
        if (v.text.isNotEmpty) env[k] = v.text;
      });
      final installed = await McpService().install(
        name: widget.entry.name,
        transport: widget.entry.transport,
        command: widget.entry.defaultCommand,
        args: widget.entry.defaultArgs,
        env: env,
        source: 'catalogue',
      );
      if (mounted) Navigator.pop(context, installed);
    } on McpException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.statusCode == 501
              ? 'MCP routes are not implemented in this daemon yet.'
              : e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entry = widget.entry;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.purple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                          color: c.purple.withValues(alpha: 0.35)),
                    ),
                    child: Text(entry.icon,
                        style: const TextStyle(fontSize: 22)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Install ${entry.label}',
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: c.textBright)),
                        const SizedBox(height: 2),
                        Text(
                          'MCP server · ${entry.transport} · ${entry.author}',
                          style: GoogleFonts.firaCode(
                              fontSize: 10.5, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(entry.description,
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: c.text,
                              height: 1.5)),
                      const SizedBox(height: 14),
                      _commandPreview(c, entry),
                      const SizedBox(height: 16),
                      if (entry.requiredEnv.isNotEmpty) ...[
                        Text('REQUIRED CONFIGURATION',
                            style: GoogleFonts.firaCode(
                              fontSize: 10,
                              color: c.textMuted,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            )),
                        const SizedBox(height: 8),
                        for (final v in entry.requiredEnv)
                          _envField(c, v, required: true),
                      ],
                      if (entry.optionalEnv.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('OPTIONAL',
                            style: GoogleFonts.firaCode(
                              fontSize: 10,
                              color: c.textMuted,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            )),
                        const SizedBox(height: 8),
                        for (final v in entry.optionalEnv)
                          _envField(c, v, required: false),
                      ],
                      if (entry.requiredEnv.isEmpty &&
                          entry.optionalEnv.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: c.green.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                                color:
                                    c.green.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.check_circle_outline_rounded,
                                  size: 14, color: c.green),
                              const SizedBox(width: 8),
                              Text('No configuration needed.',
                                  style: GoogleFonts.inter(
                                      fontSize: 11.5,
                                      color: c.text)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.red.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 14, color: c.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: GoogleFonts.firaCode(
                                fontSize: 11, color: c.red)),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton(
                    onPressed:
                        _saving ? null : () => Navigator.pop(context),
                    child: Text('Cancel',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _saving || !_isValid ? null : _install,
                    icon: _saving
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.white),
                          )
                        : const Icon(Icons.download_rounded,
                            size: 14, color: Colors.white),
                    label: Text(
                      _saving ? 'Installing…' : 'Install server',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.purple,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commandPreview(AppColors c, McpCatalogueEntry entry) {
    final cmd = '${entry.defaultCommand} ${entry.defaultArgs.join(" ")}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.terminal_rounded, size: 13, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              cmd,
              maxLines: 2,
              style: GoogleFonts.firaCode(
                  fontSize: 11, color: c.textBright, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _envField(AppColors c, McpEnvVar v, {required bool required}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(v.label,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              if (required) ...[
                const SizedBox(width: 4),
                Text('*',
                    style: GoogleFonts.inter(fontSize: 12, color: c.red)),
              ],
              const Spacer(),
              Text(v.name,
                  style: GoogleFonts.firaCode(
                      fontSize: 9.5, color: c.textMuted)),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _envCtrls[v.name],
            obscureText: v.isSecret && !(_showPlain[v.name] ?? false),
            autocorrect: !v.isSecret,
            enableSuggestions: !v.isSecret,
            onChanged: (_) => setState(() {}),
            style: GoogleFonts.firaCode(fontSize: 12, color: c.textBright),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: c.bg,
              hintText: v.placeholder ?? '',
              hintStyle:
                  GoogleFonts.firaCode(fontSize: 12, color: c.textDim),
              suffixIcon: v.isSecret
                  ? IconButton(
                      iconSize: 14,
                      icon: Icon(
                        (_showPlain[v.name] ?? false)
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: c.textMuted,
                      ),
                      onPressed: () => setState(() =>
                          _showPlain[v.name] =
                              !(_showPlain[v.name] ?? false)),
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
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
                borderSide: BorderSide(color: c.purple, width: 1.2),
              ),
            ),
          ),
          if (v.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(v.description,
                style: GoogleFonts.inter(
                    fontSize: 10.5, color: c.textMuted, height: 1.4)),
          ],
        ],
      ),
    );
  }
}
