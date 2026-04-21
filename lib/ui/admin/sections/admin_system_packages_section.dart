/// Admin → System packages. Lists every package installed at the
/// daemon level (`scope=system`) and lets the admin uninstall or
/// upgrade them. Installs happen through the Hub with the scope
/// radio set to "All users" — this section is the inverse view
/// (audit + revoke).
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/app_package.dart';
import '../../../services/package_service.dart';
import '../../../theme/app_theme.dart';
import '../../common/remote_icon.dart';
import '../../common/themed_dialogs.dart';
import '../../packages/install_flow.dart';
import '_section_scaffold.dart';

class AdminSystemPackagesSection extends StatefulWidget {
  const AdminSystemPackagesSection({super.key});

  @override
  State<AdminSystemPackagesSection> createState() =>
      _AdminSystemPackagesSectionState();
}

class _AdminSystemPackagesSectionState
    extends State<AdminSystemPackagesSection> {
  final _svc = PackageService();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await _svc.list();
    } on PackageException {
      // ignore — render the empty state below
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// Filter to system-scoped packages only — the user-scope
  /// installs of every other user are server-side hidden anyway,
  /// but we play defense and double-filter on the badge here.
  List<AppPackage> get _systemPackages =>
      _svc.packages.where((p) => p.isSystemScope).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AdminSectionScaffold(
      title: 'admin.section_system_packages'.tr(),
      subtitle: 'admin.sys_pkgs_subtitle'.tr(),
      loading: _loading,
      onRefresh: _load,
      headerActions: [
        ElevatedButton.icon(
          onPressed: _installSystem,
          icon: const Icon(Icons.add_rounded, size: 14),
          label: Text('admin.sys_pkgs_install_btn'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w700)),
          style: ElevatedButton.styleFrom(
            backgroundColor: c.purple,
            foregroundColor: Colors.white,
            elevation: 0,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
        ),
      ],
      child: _systemPackages.isEmpty
          ? _buildEmpty(c)
          : Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < _systemPackages.length; i++) ...[
                    _SystemPackageRow(
                      pkg: _systemPackages[i],
                      onUninstall: () =>
                          _confirmUninstall(_systemPackages[i]),
                    ),
                    if (i < _systemPackages.length - 1)
                      Divider(height: 1, color: c.border),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildEmpty(AppColors c) => Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2_outlined,
                  size: 36, color: c.textMuted),
              const SizedBox(height: 12),
              Text('admin.sys_pkgs_empty_title'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 13.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              SizedBox(
                width: 360,
                child: Text(
                  'admin.sys_pkgs_empty_body'.tr(),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.textMuted, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _installSystem() async {
    // Reuse the existing install flow which already prompts for
    // scope when the caller is admin. Falls through with scope=user
    // if the admin picks "Just me".
    await PackageInstallFlow.install(
      context,
      sourceType: 'local',
      sourceUri: '',
    );
    if (mounted) _load();
  }

  Future<void> _confirmUninstall(AppPackage pkg) async {
    final ok = await showThemedConfirmDialog(
      context,
      title: 'admin.sys_pkgs_uninstall_title'
          .tr(namedArgs: {'name': pkg.name}),
      body: 'admin.sys_pkgs_uninstall_body'.tr(),
      confirmLabel: 'admin.sys_pkgs_uninstall'.tr(),
      destructive: true,
    );
    if (ok != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _svc.uninstall(pkg.packageId);
      messenger.showSnackBar(SnackBar(
        content: Text('admin.sys_pkgs_uninstalled'
            .tr(namedArgs: {'name': pkg.name})),
      ));
    } on PackageException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _SystemPackageRow extends StatefulWidget {
  final AppPackage pkg;
  final VoidCallback onUninstall;
  const _SystemPackageRow({
    required this.pkg,
    required this.onUninstall,
  });

  @override
  State<_SystemPackageRow> createState() => _SystemPackageRowState();
}

class _SystemPackageRowState extends State<_SystemPackageRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pkg = widget.pkg;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        color: _h ? c.surfaceAlt : Colors.transparent,
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: RemoteIcon(
                id: pkg.deployedAppId ?? pkg.packageId,
                kind: RemoteIconKind.app,
                size: 36,
                transparent: true,
                emojiFallback: pkg.icon,
                nameFallback: pkg.name,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(pkg.name,
                          style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: c.textBright)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(
                              color: c.blue.withValues(alpha: 0.35)),
                        ),
                        child: Text('admin.sys_badge_system'.tr(),
                            style: GoogleFonts.firaCode(
                                fontSize: 8.5,
                                color: c.blue,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5)),
                      ),
                      const SizedBox(width: 6),
                      Text('v${pkg.version}',
                          style: GoogleFonts.firaCode(
                              fontSize: 9.5, color: c.textMuted)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    pkg.description.isNotEmpty
                        ? pkg.description
                        : pkg.packageId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: c.textMuted,
                        height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'admin.sys_pkgs_uninstall'.tr(),
              iconSize: 14,
              icon: Icon(Icons.delete_outline_rounded, color: c.red),
              onPressed: widget.onUninstall,
            ),
          ],
        ),
      ),
    );
  }
}
