/// Notifications section — toggle which events trigger desktop
/// notifications, sound, and quiet hours. All locally persisted via
/// [PreferencesService] so no daemon dependency.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../services/preferences_service.dart';
import '../../../theme/app_theme.dart';
import '_shared.dart';

class NotificationsSection extends StatelessWidget {
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<PreferencesService>();
    return SectionScaffold(
      title: 'settings.section_notifications'.tr(),
      subtitle:
          'settings.section_notifications_subtitle'.tr(),
      icon: Icons.notifications_none_rounded,
      children: [
        SettingsCard(
          label: 'settings.notif_channels'.tr(),
          children: [
            _ToggleRow(
              icon: Icons.desktop_windows_outlined,
              label: 'settings.notif_desktop'.tr(),
              subtitle: 'settings.notif_desktop_hint'.tr(),
              value: prefs.notifyDesktop,
              onChanged: (v) => prefs.setNotify(desktop: v),
            ),
            _ToggleRow(
              icon: Icons.phone_android_rounded,
              label: 'settings.notif_push'.tr(),
              subtitle:
                  'Delivered to the registered devices (FCM). Degrades gracefully when no device is registered.',
              value: prefs.notifyPush,
              onChanged: (v) => prefs.setNotify(push: v),
            ),
            _ToggleRow(
              icon: Icons.volume_up_outlined,
              label: 'settings.notif_sound'.tr(),
              subtitle: 'settings.notif_sound_hint'.tr(),
              value: prefs.notifySound,
              onChanged: (v) => prefs.setNotify(sound: v),
            ),
            _EmailChannelRow(prefs: prefs),
          ],
        ),

        SettingsCard(
          label: 'settings.notif_events'.tr(),
          children: [
            _ToggleRow(
              icon: Icons.check_circle_outline_rounded,
              label: 'settings.notif_activation_completed'.tr(),
              subtitle:
                  'When a background app finishes a run successfully',
              value: prefs.notifyOnCompletion,
              onChanged: (v) => prefs.setNotify(onCompletion: v),
            ),
            _ToggleRow(
              icon: Icons.error_outline_rounded,
              label: 'settings.notif_activation_failed'.tr(),
              subtitle: 'settings.notif_activation_failed_hint'.tr(),
              value: prefs.notifyOnError,
              onChanged: (v) => prefs.setNotify(onError: v),
            ),
            _ToggleRow(
              icon: Icons.alternate_email_rounded,
              label: 'settings.notif_mentions'.tr(),
              subtitle: 'settings.notif_mentions_hint'.tr(),
              value: prefs.notifyOnMention,
              onChanged: (v) => prefs.setNotify(onMention: v),
            ),
          ],
        ),

        SettingsCard(
          label: 'settings.notif_quiet_hours'.tr(),
          children: [
            _QuietHoursRow(prefs: prefs),
          ],
        ),
      ],
    );
  }
}

class _EmailChannelRow extends StatefulWidget {
  final PreferencesService prefs;
  const _EmailChannelRow({required this.prefs});

  @override
  State<_EmailChannelRow> createState() => _EmailChannelRowState();
}

class _EmailChannelRowState extends State<_EmailChannelRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.prefs.channelEmail ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mail_outline_rounded, size: 16, color: c.textMuted),
              const SizedBox(width: 12),
              Text(
                'Email channel',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: c.textBright,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(
              'Send a copy of every event-matching notification to this address.',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: c.textMuted,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: TextField(
              controller: _ctrl,
              keyboardType: TextInputType.emailAddress,
              style: GoogleFonts.inter(
                  fontSize: 12.5, color: c.textBright),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: c.surfaceAlt,
                hintText: 'you@example.com',
                hintStyle:
                    GoogleFonts.inter(fontSize: 12, color: c.textDim),
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
                  borderSide: BorderSide(color: c.accentPrimary, width: 1.4),
                ),
                suffixIcon: _ctrl.text.trim() != widget.prefs.channelEmail
                    ? IconButton(
                        iconSize: 14,
                        tooltip: 'common.save'.tr(),
                        icon: Icon(Icons.check_rounded, color: c.green),
                        onPressed: () {
                          widget.prefs.setChannelEmail(_ctrl.text.trim());
                          setState(() {});
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) => widget.prefs.setChannelEmail(v.trim()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: icon,
      label: label,
      subtitle: subtitle,
      trailing: Switch.adaptive(
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _QuietHoursRow extends StatelessWidget {
  final PreferencesService prefs;
  const _QuietHoursRow({required this.prefs});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final start = prefs.quietHoursStart;
    final end = prefs.quietHoursEnd;
    final enabled = start != null && end != null;
    final summary = enabled
        ? '${_fmt(start)} → ${_fmt(end)}'
        : 'Off — notify any time of day';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bedtime_outlined, size: 16, color: c.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quiet hours',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      style: GoogleFonts.firaCode(
                        fontSize: 11.5,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: enabled,
                onChanged: (v) {
                  if (v) {
                    prefs.setQuietHours(start: 22, end: 7);
                  } else {
                    prefs.setQuietHours(start: null, end: null);
                  }
                },
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _HourPicker(
                    label: 'settings.notif_from'.tr(),
                    value: start,
                    onChanged: (v) => prefs.setQuietHours(start: v, end: end),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _HourPicker(
                    label: 'settings.notif_to'.tr(),
                    value: end,
                    onChanged: (v) => prefs.setQuietHours(start: start, end: v),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _fmt(int hour) =>
      '${hour.toString().padLeft(2, '0')}:00';
}

class _HourPicker extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  const _HourPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.firaCode(
            fontSize: 9.5,
            color: c.textMuted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: value,
              isDense: true,
              isExpanded: true,
              dropdownColor: c.surface,
              style: GoogleFonts.firaCode(
                fontSize: 12,
                color: c.textBright,
              ),
              items: [
                for (var h = 0; h < 24; h++)
                  DropdownMenuItem(
                    value: h,
                    child: Text('${h.toString().padLeft(2, '0')}:00'),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }
}
