import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/auth_service.dart';
import '../../../services/onboarding_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../../ds/ds_avatar.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

class ProfileStep extends StatefulWidget {
  const ProfileStep({super.key});

  @override
  State<ProfileStep> createState() => _ProfileStepState();
}

class _ProfileStepState extends State<ProfileStep> {
  late final TextEditingController _name;
  String _role = 'developer';

  @override
  void initState() {
    super.initState();
    final initial = AuthService().currentUser?.displayName ??
        OnboardingService().displayName ??
        '';
    _name = TextEditingController(text: initial);
    _role = OnboardingService().role == 'other'
        ? 'developer'
        : OnboardingService().role;
    _sync();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _sync() {
    OnboardingService().displayName =
        _name.text.trim().isEmpty ? null : _name.text.trim();
    OnboardingService().avatarInitialsSeed = _name.text.trim();
    OnboardingService().role = _role;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WizardNav.of(context).setCanAdvance(_name.text.trim().length >= 2);
    });
  }

  String get _initials {
    final parts =
        _name.text.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    if (parts.isEmpty) return 'D';
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length.clamp(0, 2));
    }
    return '${parts.first[0]}${parts.last[0]}';
  }

  @override
  Widget build(BuildContext context) {
    final compact = DsBreakpoint.isCompact(context);
    return WizardStepScaffold(
      eyebrow: 'onboarding.step_01'.tr(),
      title: 'onboarding.profile_title_long'.tr(),
      subtitle: 'onboarding.profile_subtitle_long'.tr(),
      canAdvance: _name.text.trim().length >= 2,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DsAvatar(
                seed: _name.text.isEmpty ? 'Digitorn' : _name.text,
                initials: _initials,
                size: compact ? 56 : 72,
              ),
              SizedBox(width: DsSpacing.x5),
              Expanded(
                child: DsInput(
                  controller: _name,
                  label: 'onboarding.profile_display_name'.tr(),
                  placeholder: 'onboarding.profile_name_placeholder'.tr(),
                  leadingIcon: Icons.person_outline,
                  autofocus: true,
                  autofillHints: const [AutofillHints.name],
                  onChanged: (_) => setState(_sync),
                ),
              ),
            ],
          ),
          SizedBox(height: DsSpacing.x7),
          _RolePicker(
            value: _role,
            onChanged: (r) => setState(() {
              _role = r;
              _sync();
            }),
          ),
        ],
      ),
    );
  }
}

class _RolePicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _RolePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final roles = [
      _Role('developer', 'onboarding.role_developer'.tr(), Icons.code,
          'onboarding.role_developer_desc'.tr()),
      _Role('analyst', 'onboarding.role_analyst'.tr(), Icons.query_stats,
          'onboarding.role_analyst_desc'.tr()),
      _Role('operator', 'onboarding.role_operator'.tr(), Icons.hub_outlined,
          'onboarding.role_operator_desc'.tr()),
      _Role('researcher', 'onboarding.role_researcher'.tr(),
          Icons.science_outlined, 'onboarding.role_researcher_desc'.tr()),
      _Role('other', 'onboarding.role_other_title'.tr(), Icons.star_outline,
          'onboarding.role_other_desc'.tr()),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('onboarding.profile_what_describes_you'.tr(),
            style: DsType.eyebrow(color: c.textMuted)),
        SizedBox(height: DsSpacing.x4),
        Wrap(
          spacing: DsSpacing.x3,
          runSpacing: DsSpacing.x3,
          children: [
            for (final r in roles)
              SizedBox(
                width: 230,
                child: DsCard(
                  selected: value == r.id,
                  onTap: () => onChanged(r.id),
                  padding: EdgeInsets.all(DsSpacing.x4),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: value == r.id
                              ? c.accentPrimary.withValues(alpha: 0.14)
                              : c.surfaceAlt,
                          borderRadius: BorderRadius.circular(DsRadius.xs),
                        ),
                        child: Icon(
                          r.icon,
                          size: 16,
                          color:
                              value == r.id ? c.accentPrimary : c.text,
                        ),
                      ),
                      SizedBox(width: DsSpacing.x4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(r.title,
                                style: DsType.h3(color: c.textBright)),
                            SizedBox(height: 1),
                            Text(
                              r.desc,
                              style: DsType.micro(color: c.textMuted)
                                  .copyWith(fontSize: 11.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Role {
  final String id;
  final String title;
  final IconData icon;
  final String desc;
  const _Role(this.id, this.title, this.icon, this.desc);
}
