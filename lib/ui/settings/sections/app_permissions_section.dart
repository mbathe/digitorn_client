/// "App permissions" section — inverse of the credentials manager.
///
/// For each app the user has used, lists the credentials granted
/// to it. Row action: Revoke. Powered by
/// `GET /api/credentials-grants` on the daemon.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/app_summary.dart';
import '../../../models/credential_v2.dart';
import '../../../services/apps_service.dart';
import '../../../services/credentials_v2_service.dart';
import '../../../theme/app_theme.dart';
import '_shared.dart';

class AppPermissionsSection extends StatefulWidget {
  const AppPermissionsSection({super.key});

  @override
  State<AppPermissionsSection> createState() => _AppPermissionsSectionState();
}

class _AppPermissionsSectionState extends State<AppPermissionsSection> {
  final _credSvc = CredentialsV2Service();
  final _appsSvc = AppsService();

  bool _loading = true;
  String? _error;
  List<CredentialGrant> _grants = const [];
  List<CredentialV2> _credentials = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_appsSvc.apps.isEmpty) {
        try {
          await _appsSvc.refresh();
        } catch (_) {}
      }
      final results = await Future.wait([
        _credSvc.listAllGrants(),
        _credSvc.list(),
      ]);
      if (!mounted) return;
      setState(() {
        _grants = results[0] as List<CredentialGrant>;
        _credentials = results[1] as List<CredentialV2>;
        _loading = false;
      });
    } on CredV2Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Map<String, List<CredentialGrant>> _groupByApp() {
    final out = <String, List<CredentialGrant>>{};
    for (final g in _grants) {
      out.putIfAbsent(g.appId, () => []).add(g);
    }
    return out;
  }

  CredentialV2? _credentialFor(String id) {
    for (final c in _credentials) {
      if (c.id == id) return c;
    }
    return null;
  }

  AppSummary? _appFor(String appId) {
    for (final a in _appsSvc.apps) {
      if (a.appId == appId) return a;
    }
    return null;
  }

  Future<void> _revoke(CredentialGrant g) async {
    try {
      await _credSvc.revoke(
          credentialId: g.credentialId, appId: g.appId);
      _load();
    } on CredV2Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SectionScaffold(
      title: 'settings.section_permissions'.tr(),
      subtitle: 'settings.section_permissions_subtitle'.tr(),
      icon: Icons.shield_outlined,
      actions: [
        IconButton(
          tooltip: 'common.refresh'.tr(),
          icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: [
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              ),
            ),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(_error!,
                  style:
                      GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
            ),
          )
        else if (_grants.isEmpty)
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.border),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined, size: 36, color: c.textMuted),
                  const SizedBox(height: 12),
                  Text('No permissions granted yet',
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.textBright)),
                  const SizedBox(height: 6),
                  Text(
                    'Open any app — it\'ll ask for the credentials it needs and you\'ll see the grants here.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                        fontSize: 11.5, color: c.textMuted, height: 1.5),
                  ),
                ],
              ),
            ),
          )
        else
          for (final entry in _groupByApp().entries) ...[
            _buildAppCard(c, entry.key, entry.value),
            const SizedBox(height: 14),
          ],
      ],
    );
  }

  Widget _buildAppCard(
      AppColors c, String appId, List<CredentialGrant> grants) {
    final app = _appFor(appId);
    final iconStr = app?.icon ?? '';
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.border),
                  ),
                  child: iconStr.isNotEmpty
                      ? Text(iconStr, style: const TextStyle(fontSize: 16))
                      : Icon(Icons.apps_rounded, size: 15, color: c.text),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app?.name ?? appId,
                          style: GoogleFonts.inter(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: c.textBright)),
                      Text(appId,
                          style: GoogleFonts.firaCode(
                              fontSize: 10.5, color: c.textMuted)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                      '${grants.length} grant${grants.length == 1 ? '' : 's'}',
                      style: GoogleFonts.firaCode(
                          fontSize: 9.5, color: c.textMuted)),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          for (var i = 0; i < grants.length; i++) ...[
            _buildGrantRow(c, grants[i]),
            if (i < grants.length - 1)
              Divider(height: 1, color: c.border),
          ],
        ],
      ),
    );
  }

  Widget _buildGrantRow(AppColors c, CredentialGrant g) {
    final cred = _credentialFor(g.credentialId);
    final providerLabel = cred?.displayProviderLabel ?? g.credentialId;
    final label = cred?.label ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Icon(Icons.key_rounded, size: 14, color: c.text),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    label.isNotEmpty
                        ? '$providerLabel · $label'
                        : providerLabel,
                    style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: c.textBright)),
                if (g.scopesGranted.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'scopes: ${g.scopesGranted.join(", ")}',
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textMuted),
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => _revoke(g),
            icon: Icon(Icons.block_rounded, size: 13, color: c.red),
            label: Text('settings.revoke'.tr(),
                style: GoogleFonts.inter(fontSize: 11, color: c.red)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
          ),
        ],
      ),
    );
  }
}
