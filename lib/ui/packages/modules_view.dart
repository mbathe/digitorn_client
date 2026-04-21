/// "Modules" tab in the Hub — lists every module the daemon
/// discovers plus the subset the current user has enabled. Modules
/// are lighter-weight than packages (shared Python bundles) and get
/// a per-row health probe so the user sees if anything's broken.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/modules_service.dart';
import '../../theme/app_theme.dart';

class ModulesView extends StatefulWidget {
  const ModulesView({super.key});

  @override
  State<ModulesView> createState() => _ModulesViewState();
}

class _ModulesViewState extends State<ModulesView> {
  final _svc = ModulesService();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _svc.refresh();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  List<Module> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _svc.catalog;
    return _svc.catalog.where((m) {
      return m.name.toLowerCase().contains(q) ||
          m.description.toLowerCase().contains(q) ||
          m.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_svc.loading && _svc.catalog.isEmpty) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.textMuted),
        ),
      );
    }
    if (_svc.error != null && _svc.catalog.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text(_svc.error!,
                  style:
                      GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () => _svc.refresh(),
                child:
                    Text('common.retry'.tr(), style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 50),
      children: [
        Row(
          children: [
            Icon(Icons.extension_outlined, size: 17, color: c.textMuted),
            const SizedBox(width: 9),
            Text(
              '${_svc.catalog.length} module${_svc.catalog.length == 1 ? '' : 's'} discovered · ${_svc.enabled.length} enabled',
              style:
                  GoogleFonts.firaCode(fontSize: 12.5, color: c.textMuted),
            ),
            const Spacer(),
            SizedBox(
              width: 260,
              height: 38,
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: GoogleFonts.inter(fontSize: 13.5, color: c.textBright),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  prefixIcon:
                      Icon(Icons.search_rounded, size: 15, color: c.textMuted),
                  hintText: 'hub.filter_modules'.tr(),
                  hintStyle:
                      GoogleFonts.inter(fontSize: 13, color: c.textMuted),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.border),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_filtered.isEmpty)
          Container(
            padding: const EdgeInsets.all(40),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.border),
            ),
            child: Text(
              _query.isNotEmpty
                  ? 'No module matches "$_query"'
                  : 'No modules discovered yet.',
              style: GoogleFonts.inter(fontSize: 13, color: c.textMuted),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _filtered.length; i++) ...[
                  _ModuleRow(
                    module: _filtered[i],
                    health: _svc.health[_filtered[i].id],
                    onProbe: () => _svc.fetchHealth(_filtered[i].id),
                    onToggle: () async {
                      final m = _filtered[i];
                      final messenger = ScaffoldMessenger.of(context);
                      final ok = m.enabled
                          ? await _svc.disable(m.id)
                          : await _svc.enable(m.id);
                      if (!mounted) return;
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? (m.enabled
                                    ? '${m.name} disabled'
                                    : '${m.name} enabled')
                                : 'Action failed',
                            style: GoogleFonts.inter(fontSize: 12),
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                  if (i < _filtered.length - 1)
                    Divider(height: 1, color: c.border),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ModuleRow extends StatelessWidget {
  final Module module;
  final ModuleHealth? health;
  final VoidCallback onProbe;
  final VoidCallback onToggle;
  const _ModuleRow({
    required this.module,
    required this.health,
    required this.onProbe,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final healthTint = health == null
        ? c.textMuted
        : (health!.isHealthy ? c.green : c.red);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Text(
              module.icon ?? '🧩',
              style: const TextStyle(fontSize: 17),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(module.name,
                        style: GoogleFonts.inter(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: c.textBright)),
                    if (module.verified) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.verified_rounded,
                          size: 13, color: c.accentPrimary),
                    ],
                    if (module.version != null) ...[
                      const SizedBox(width: 8),
                      Text('v${module.version}',
                          style: GoogleFonts.firaCode(
                              fontSize: 11, color: c.textMuted)),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  module.description.isNotEmpty
                      ? module.description
                      : module.id,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 12.5, color: c.text, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Health indicator
          Tooltip(
            message: health == null
                ? 'Not probed yet · click to check'
                : '${health!.status}${health!.error != null ? "\n${health!.error}" : ""}',
            child: InkWell(
              onTap: onProbe,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: healthTint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: healthTint.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: healthTint,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      health?.status.toUpperCase() ?? 'PROBE',
                      style: GoogleFonts.firaCode(
                          fontSize: 10,
                          color: healthTint,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Switch.adaptive(value: module.enabled, onChanged: (_) => onToggle()),
        ],
      ),
    );
  }
}
