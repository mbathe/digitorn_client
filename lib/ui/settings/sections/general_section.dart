/// "General" settings section — user identity, account info, sign-out.
///
/// Every field is live-wired to the daemon:
///   * Avatar → POST /api/users/me/avatar (multipart) + DELETE
///   * Profile → PUT /api/users/me/profile (display_name / phone /
///     locale / timezone)
///   * Password → POST /api/users/me/password
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../services/auth_service.dart';
import '../../../services/devices_service.dart';
import '../../../theme/app_theme.dart';
import '../../common/themed_dialogs.dart';
import '_shared.dart';

class GeneralSection extends StatelessWidget {
  const GeneralSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final auth = context.watch<AuthService>();
    final user = auth.currentUser;

    return SectionScaffold(
      title: 'settings.section_general'.tr(),
      subtitle: 'settings.section_general_subtitle'.tr(),
      icon: Icons.person_outline_rounded,
      children: [
        // ── Identity card ────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(20),
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              _AvatarEditor(
                user: user,
                onPick: () => _pickAndUploadAvatar(context, auth),
                onClear: () => auth.deleteAvatar(),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.displayName ?? user?.userId ?? 'Unknown user',
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                      ),
                    ),
                    if (user?.email != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        user!.email!,
                        style: GoogleFonts.firaCode(
                          fontSize: 11.5,
                          color: c.textMuted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (user?.isAdmin == true)
                          _Pill(
                            icon: Icons.shield_outlined,
                            label: 'admin',
                            tint: c.purple,
                          ),
                        for (final r in user?.roles ?? const <String>[])
                          if (r != 'admin')
                            _Pill(
                              icon: Icons.label_outline_rounded,
                              label: r,
                              tint: c.accentPrimary,
                            ),
                        if (user?.createdAt != null)
                          _Pill(
                            icon: Icons.calendar_today_rounded,
                            label: 'joined ${_shortDate(user!.createdAt!)}',
                            tint: c.textMuted,
                          ),
                        if (user?.updatedAt != null)
                          _Pill(
                            icon: Icons.edit_calendar_outlined,
                            label: 'updated ${_shortDate(user!.updatedAt!)}',
                            tint: c.textMuted,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        SettingsCard(
          label: 'settings.account'.tr(),
          children: [
            SettingsRow(
              icon: Icons.badge_outlined,
              label: 'settings.display_name'.tr(),
              subtitle: user?.displayName?.trim().isNotEmpty == true
                  ? user!.displayName!
                  : 'Not set',
              trailing:
                  Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
              onTap: () => _editDisplayName(context, auth),
            ),
            SettingsRow(
              icon: Icons.phone_outlined,
              label: 'settings.phone'.tr(),
              subtitle: user?.phone?.trim().isNotEmpty == true
                  ? user!.phone!
                  : 'Not set',
              trailing:
                  Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
              onTap: () => _editPhone(context, auth),
            ),
            SettingsRow(
              icon: Icons.alternate_email_rounded,
              label: 'settings.email'.tr(),
              subtitle: user?.email ?? '—',
              trailing:
                  _ReadOnlyChip(label: 'settings.admin_managed'.tr()),
            ),
            SettingsRow(
              icon: Icons.lock_reset_rounded,
              label: 'settings.change_password'.tr(),
              subtitle: 'settings.change_password_hint'.tr(),
              trailing:
                  Icon(Icons.chevron_right_rounded, size: 16, color: c.textMuted),
              onTap: () => _changePassword(context, auth),
            ),
          ],
        ),

        SettingsCard(
          label: 'settings.region'.tr(),
          children: [
            SettingsRow(
              icon: Icons.language_rounded,
              label: 'settings.locale'.tr(),
              subtitle: user?.locale?.trim().isNotEmpty == true
                  ? user!.locale!
                  : 'System default',
              trailing:
                  Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
              onTap: () => _editLocale(context, auth),
            ),
            SettingsRow(
              icon: Icons.schedule_rounded,
              label: 'settings.timezone'.tr(),
              subtitle: user?.timezone?.trim().isNotEmpty == true
                  ? user!.timezone!
                  : 'System default',
              trailing:
                  Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
              onTap: () => _editTimezone(context, auth),
            ),
          ],
        ),

        // ── Notification preferences ─────────────────────────────
        // The daemon's 2026-04 profile schema added
        // `attributes.notification_prefs` — server-synced so the
        // same preferences follow the user across devices. Deep-merge
        // means we only send the keys that change.
        _NotificationPrefsCard(
          prefs: user?.notificationPrefs ?? const <String, dynamic>{},
          onToggle: (key, value) async {
            final current = Map<String, dynamic>.from(
                user?.notificationPrefs ?? const <String, dynamic>{});
            current[key] = value;
            final ok = await auth.updateProfile(notificationPrefs: current);
            if (!context.mounted) return;
            _toast(
              context,
              ok
                  ? 'settings.saved'.tr()
                  : 'Failed: ${auth.lastError ?? ''}',
            );
          },
        ),

        // ── Registered devices ───────────────────────────────────
        const _DevicesCard(),

        // ── Daemon connection ────────────────────────────────────
        SettingsCard(
          label: 'settings.connection'.tr(),
          children: [
            SettingsRow(
              icon: Icons.dns_outlined,
              label: 'settings.daemon_url'.tr(),
              subtitle: auth.baseUrl,
            ),
            SettingsRow(
              icon: Icons.vpn_key_outlined,
              label: 'settings.authenticated'.tr(),
              subtitle: auth.isAuthenticated
                  ? 'Bearer token loaded from secure storage'
                  : 'Not authenticated',
              trailing: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: auth.isAuthenticated ? c.green : c.red,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),

        // ── Sign out ─────────────────────────────────────────────
        Center(
          child: OutlinedButton.icon(
            onPressed: () => auth.logout(),
            icon: Icon(Icons.logout_rounded, size: 16, color: c.red),
            label: Text(
              'Sign out',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: c.red,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.red.withValues(alpha: 0.4)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  // ── Handlers ─────────────────────────────────────────────────────────

  Future<void> _pickAndUploadAvatar(
      BuildContext context, AuthService auth) async {
    const typeGroup = XTypeGroup(
      label: 'images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      if (!context.mounted) return;
      _toast(context, 'Avatar must be under 5 MB');
      return;
    }
    final ok = await auth.uploadAvatar(
      bytes: bytes,
      filename: file.name,
      contentType: _mimeFor(file.name),
    );
    if (!context.mounted) return;
    _toast(
        context,
        ok
            ? 'settings.toast_avatar_updated'.tr()
            : 'settings.toast_upload_failed'
                .tr(namedArgs: {'error': auth.lastError ?? ''}));
  }

  Future<void> _editDisplayName(
      BuildContext context, AuthService auth) async {
    final value = await _promptText(
      context,
      title: 'settings.display_name'.tr(),
      hint: 'settings.hint_display_name'.tr(),
      initial: auth.currentUser?.displayName ?? '',
    );
    if (value == null) return;
    final ok = await auth.updateProfile(displayName: value);
    if (!context.mounted) return;
    _toast(
        context,
        ok
            ? 'settings.toast_display_name_saved'.tr()
            : 'settings.toast_update_failed'
                .tr(namedArgs: {'error': auth.lastError ?? ''}));
  }

  Future<void> _editPhone(BuildContext context, AuthService auth) async {
    final value = await _promptText(
      context,
      title: 'settings.phone'.tr(),
      hint: 'settings.hint_phone'.tr(),
      initial: auth.currentUser?.phone ?? '',
    );
    if (value == null) return;
    final ok = await auth.updateProfile(phone: value);
    if (!context.mounted) return;
    _toast(
        context,
        ok
            ? 'settings.toast_phone_saved'.tr()
            : 'settings.toast_update_failed'
                .tr(namedArgs: {'error': auth.lastError ?? ''}));
  }

  Future<void> _editLocale(BuildContext context, AuthService auth) async {
    final value = await _promptText(
      context,
      title: 'settings.locale'.tr(),
      hint: 'settings.hint_locale'.tr(),
      initial: auth.currentUser?.locale ?? '',
    );
    if (value == null) return;
    final ok = await auth.updateProfile(locale: value);
    if (!context.mounted) return;
    _toast(
        context,
        ok
            ? 'settings.toast_locale_saved'.tr()
            : 'settings.toast_update_failed'
                .tr(namedArgs: {'error': auth.lastError ?? ''}));
  }

  Future<void> _editTimezone(BuildContext context, AuthService auth) async {
    final value = await _promptText(
      context,
      title: 'settings.timezone'.tr(),
      hint: 'settings.hint_timezone'.tr(),
      initial: auth.currentUser?.timezone ?? '',
    );
    if (value == null) return;
    final ok = await auth.updateProfile(timezone: value);
    if (!context.mounted) return;
    _toast(
        context,
        ok
            ? 'settings.toast_timezone_saved'.tr()
            : 'settings.toast_update_failed'
                .tr(namedArgs: {'error': auth.lastError ?? ''}));
  }

  Future<void> _changePassword(
      BuildContext context, AuthService auth) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (result == null) return;
    final ok = await auth.changePassword(
      oldPassword: result.$1,
      newPassword: result.$2,
    );
    if (!context.mounted) return;
    _toast(
        context,
        ok
            ? 'settings.toast_password_changed'.tr()
            : 'settings.toast_update_failed'.tr(namedArgs: {
                'error':
                    auth.lastError ?? 'settings.toast_rejected'.tr()
              }));
  }

  Future<String?> _promptText(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
  }) {
    return showThemedPromptDialog(
      context,
      title: title,
      hint: hint,
      initial: initial,
    );
  }

  static String _shortDate(DateTime t) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[t.month - 1]} ${t.day}, ${t.year}';
  }

  static String _mimeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.inter(fontSize: 12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

/// Avatar widget that renders the real image fetched from the daemon
/// when one is set, and a hash-gradient + initials fallback otherwise.
/// Clicking opens the picker; long-press clears the current avatar.
class _AvatarEditor extends StatefulWidget {
  final AuthUser? user;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _AvatarEditor({
    required this.user,
    required this.onPick,
    required this.onClear,
  });

  @override
  State<_AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends State<_AvatarEditor> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final user = widget.user;
    final displayName = user?.displayName ?? user?.userId ?? '?';
    final url = AuthService().avatarAbsoluteUrl;

    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onPick,
        onLongPress: url == null ? null : widget.onClear,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _GradientInitialAvatar(displayName: displayName),
            if (url != null)
              ClipOval(
                child: Image.network(
                  url,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  headers: AuthService().authImageHeaders,
                  errorBuilder: (_, _, _) =>
                      _GradientInitialAvatar(displayName: displayName),
                ),
              ),
            if (_h)
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.overlay,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.photo_camera_outlined,
                    size: 20, color: c.onAccent),
              ),
          ],
        ),
      ),
    );
  }
}

class _GradientInitialAvatar extends StatelessWidget {
  final String displayName;
  const _GradientInitialAvatar({required this.displayName});

  @override
  Widget build(BuildContext context) {
    final hash = displayName.hashCode;
    final c1 =
        HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.55, 0.5).toColor();
    final c2 = HSLColor.fromAHSL(
            1, ((hash ~/ 7) % 360).toDouble(), 0.55, 0.4)
        .toColor();
    return Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [c1, c2]),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: c1.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        _initials(displayName),
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: context.colors.contrastOn(c1),
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'[\s@._-]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first
          .substring(0, parts.first.length.clamp(0, 2))
          .toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fieldStyle =
        GoogleFonts.inter(fontSize: 13, color: c.textBright);
    return themedAlertDialog(
      context,
      title: 'settings.change_password'.tr(),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _old,
              obscureText: true,
              style: fieldStyle,
              decoration:
                  themedInputDecoration(context, labelText: 'Current password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _new,
              obscureText: true,
              style: fieldStyle,
              decoration:
                  themedInputDecoration(context, labelText: 'New password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirm,
              obscureText: true,
              style: fieldStyle,
              decoration:
                  themedInputDecoration(context, labelText: 'Confirm'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: GoogleFonts.firaCode(fontSize: 11, color: c.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('common.cancel'.tr(),
              style:
                  GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ),
        ElevatedButton(
          onPressed: () {
            if (_new.text.length < 8) {
              setState(() => _error = 'New password must be ≥ 8 characters.');
              return;
            }
            if (_new.text != _confirm.text) {
              setState(() => _error = 'Passwords don\'t match.');
              return;
            }
            Navigator.pop<(String, String)>(
                context, (_old.text, _new.text));
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: c.accentPrimary,
            foregroundColor: c.onAccent,
            elevation: 0,
          ),
          child: Text('settings.change'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _DevicesCard extends StatefulWidget {
  const _DevicesCard();
  @override
  State<_DevicesCard> createState() => _DevicesCardState();
}

class _DevicesCardState extends State<_DevicesCard> {
  final _svc = DevicesService();
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
    await _svc.refreshList();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final devices = _svc.devices;
    return SettingsCard(
      label: 'settings.registered_devices'.tr(),
      children: [
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              ),
            ),
          )
        else if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Text(
              'No device registered yet — this client will show up after the next sync.',
              style: GoogleFonts.inter(fontSize: 11.5, color: c.textMuted),
            ),
          )
        else
          for (final d in devices)
            _DeviceRow(
              device: d,
              onRevoke: () => _confirmRevoke(d.id),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _loading ? null : _load,
                icon: Icon(Icons.refresh_rounded, size: 14, color: c.textMuted),
                label: Text(
                  'Refresh',
                  style: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmRevoke(String id) async {
    final ok = await showThemedConfirmDialog(
      context,
      title: 'settings.revoke_device_title'.tr(),
      body: 'The device will be signed out and its sessions closed. '
          'It can re-register on next launch.',
      confirmLabel: 'settings.revoke'.tr(),
      destructive: true,
    );
    if (ok != true) return;
    await _svc.revoke(id);
  }
}

class _DeviceRow extends StatelessWidget {
  final Device device;
  final VoidCallback onRevoke;
  const _DeviceRow({required this.device, required this.onRevoke});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final icon = switch (device.platform) {
      'windows' || 'linux' || 'macos' => Icons.desktop_windows_outlined,
      'web' => Icons.language_rounded,
      'android' || 'ios' => Icons.smartphone_outlined,
      _ => Icons.devices_other_rounded,
    };
    final lastSeen = device.lastSeenAt != null
        ? 'last seen ${_ago(device.lastSeenAt!)}'
        : 'never seen';
    return SettingsRow(
      icon: icon,
      label: device.name,
      subtitle: '${device.platform} · $lastSeen',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (device.isCurrent)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: c.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: c.green.withValues(alpha: 0.35)),
              ),
              child: Text(
                'THIS',
                style: GoogleFonts.firaCode(
                  fontSize: 8.5,
                  color: c.green,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            TextButton(
              onPressed: onRevoke,
              child: Text('settings.revoke'.tr(),
                  style: GoogleFonts.inter(fontSize: 11, color: c.red)),
            ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;
  const _Pill({required this.icon, required this.label, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: tint),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: tint,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyChip extends StatelessWidget {
  final String label;
  const _ReadOnlyChip({required this.label});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: c.border),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 8.5,
          color: c.textMuted,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─── Notification preferences card ──────────────────────────────
//
// Renders three toggles backed by `attributes.notification_prefs.*`.
// Each toggle fires a deep-merge PUT so untouched keys (marketing
// etc.) are preserved. The card is the primary surface exposing
// the daemon's 2026-04 server-synced notification bag to the user.

class _NotificationPrefsCard extends StatelessWidget {
  final Map<String, dynamic> prefs;
  final Future<void> Function(String key, bool value) onToggle;

  const _NotificationPrefsCard({
    required this.prefs,
    required this.onToggle,
  });

  bool _read(String key, {bool defaultValue = false}) {
    final raw = prefs[key];
    if (raw is bool) return raw;
    return defaultValue;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      label: 'settings.notification_prefs'.tr(),
      children: [
        _Toggle(
          icon: Icons.mail_outline_rounded,
          label: 'settings.notify_email'.tr(),
          value: _read('email', defaultValue: true),
          onChanged: (v) => onToggle('email', v),
        ),
        _Toggle(
          icon: Icons.notifications_active_outlined,
          label: 'settings.notify_push'.tr(),
          value: _read('push', defaultValue: false),
          onChanged: (v) => onToggle('push', v),
        ),
        _Toggle(
          icon: Icons.campaign_outlined,
          label: 'settings.notify_marketing'.tr(),
          value: _read('marketing', defaultValue: false),
          onChanged: (v) => onToggle('marketing', v),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Toggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: icon,
      label: label,
      subtitle: value
          ? 'settings.toggle_on'.tr()
          : 'settings.toggle_off'.tr(),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
