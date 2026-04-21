/// Admin-only strip displayed at the top of the Library tab when
/// the current user can see disabled apps. For each entry:
///
///   * `has_bundle: true`  → [Re-enable] + [Purge permanently]
///   * `has_bundle: false` → only [Purge permanently] — the bundle
///     is gone, re-enable can't work.
///
/// Non-admins don't see this section at all — the daemon silently
/// ignores the `include_disabled=true` flag for them.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/apps_service.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import 'lifecycle_dialogs.dart';

class DisabledAppsSection extends StatefulWidget {
  /// Called after a successful reactivate / purge so the outer page
  /// can refresh its main list.
  final VoidCallback onChanged;
  const DisabledAppsSection({super.key, required this.onChanged});

  @override
  State<DisabledAppsSection> createState() => _DisabledAppsSectionState();
}

class _DisabledAppsSectionState extends State<DisabledAppsSection> {
  bool _loading = false;
  List<DisabledApp> _disabled = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (AuthService().currentUser?.isAdmin != true) {
      setState(() => _disabled = const []);
      return;
    }
    setState(() => _loading = true);
    final list = await AppsService().fetchDisabledApps();
    if (!mounted) return;
    setState(() {
      _disabled = list;
      _loading = false;
    });
  }

  Future<void> _enable(DisabledApp app) async {
    // For user-scoped installs we MUST pass scope + user_id so the
    // daemon reactivates the right row. For system installs both
    // stay null and the daemon targets the shared install.
    final ok = await AppLifecycleDialogs.enable(
      context,
      appId: app.appId,
      appName: app.name,
      scope: app.isUserScope ? 'user' : null,
      userId: app.isUserScope ? app.ownerUserId : null,
    );
    if (ok && mounted) {
      await _load();
      widget.onChanged();
    }
  }

  Future<void> _purge(DisabledApp app) async {
    final ok = await AppLifecycleDialogs.deletePermanent(
      context,
      appId: app.appId,
      appName: app.name,
      scope: app.isUserScope ? 'user' : 'system',
    );
    if (ok && mounted) {
      await _load();
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (AuthService().currentUser?.isAdmin != true) {
      return const SizedBox.shrink();
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (_disabled.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final systemInstalls =
        _disabled.where((a) => a.isSystemScope).toList();
    final userInstalls =
        _disabled.where((a) => a.isUserScope).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.orange.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.orange.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.admin_panel_settings_rounded,
                  size: 14, color: c.orange),
              const SizedBox(width: 6),
              Text(
                'Disabled apps',
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: c.orange,
                    letterSpacing: 0.3),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('${_disabled.length}',
                    style: GoogleFonts.firaCode(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: c.orange)),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: _load,
                icon: Icon(Icons.refresh_rounded, color: c.textDim),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (systemInstalls.isNotEmpty) ...[
            _GroupHeader(
                label: 'System installs', icon: Icons.public_rounded),
            for (final app in systemInstalls)
              _DisabledRow(
                app: app,
                onEnable: () => _enable(app),
                onPurge: () => _purge(app),
              ),
          ],
          if (userInstalls.isNotEmpty) ...[
            if (systemInstalls.isNotEmpty) const SizedBox(height: 10),
            _GroupHeader(
                label: 'User installs', icon: Icons.person_rounded),
            for (final app in userInstalls)
              _DisabledRow(
                app: app,
                onEnable: () => _enable(app),
                onPurge: () => _purge(app),
              ),
          ],
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  const _GroupHeader({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Row(
        children: [
          Icon(icon, size: 11, color: c.textDim),
          const SizedBox(width: 5),
          Text(
            label.toUpperCase(),
            style: GoogleFonts.firaCode(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: c.textDim,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _DisabledRow extends StatelessWidget {
  final DisabledApp app;
  final VoidCallback onEnable;
  final VoidCallback onPurge;
  const _DisabledRow({
    required this.app,
    required this.onEnable,
    required this.onPurge,
  });

  String _ageString() {
    final at = app.disabledAt;
    if (at == null) return '';
    final d = DateTime.now().toUtc().difference(at);
    if (d.inDays >= 1) return '${d.inDays}d ago';
    if (d.inHours >= 1) return '${d.inHours}h ago';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final canEnable = app.hasBundle;
    // For user-scoped rows the owner id is the important reactivation
    // handle — show it prominently so the admin knows *whose* install
    // they're touching.
    final enableLabel = app.isUserScope && app.ownerUserId.isNotEmpty
        ? 'Re-enable for ${_shortId(app.ownerUserId)}'
        : 'Re-enable';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      app.name.isNotEmpty ? app.name : app.appId,
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.text),
                    ),
                    if (app.version.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        'v${app.version}',
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textDim),
                      ),
                    ],
                    if (app.isUserScope &&
                        app.ownerUserId.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person_rounded,
                                size: 9, color: c.blue),
                            const SizedBox(width: 3),
                            Text(
                              _shortId(app.ownerUserId),
                              style: GoogleFonts.firaCode(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  color: c.blue),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      _ageString(),
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textDim),
                    ),
                  ],
                ),
                if (app.disabledReason != null &&
                    app.disabledReason!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '"${app.disabledReason!}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        color: c.textMuted,
                        fontStyle: FontStyle.italic),
                  ),
                ],
                if (!app.hasBundle) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Bundle lost — cannot be re-enabled',
                    style: GoogleFonts.inter(
                        fontSize: 10.5, color: c.red),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (canEnable)
            OutlinedButton.icon(
              onPressed: onEnable,
              icon: Icon(Icons.play_circle_outline_rounded,
                  size: 13, color: c.green),
              label: Text(enableLabel,
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.green)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.green.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          const SizedBox(width: 6),
          TextButton.icon(
            onPressed: onPurge,
            icon: Icon(Icons.delete_forever_rounded,
                size: 13, color: c.red),
            label: Text('Purge',
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.red)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  static String _shortId(String uid) =>
      uid.length > 12 ? '${uid.substring(0, 12)}…' : uid;
}
