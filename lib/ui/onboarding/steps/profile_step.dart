import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/auth_service.dart';
import '../../../services/onboarding_service.dart';
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

  @override
  void initState() {
    super.initState();
    final initial = AuthService().currentUser?.displayName ??
        OnboardingService().displayName ??
        '';
    _name = TextEditingController(text: initial);
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
      content: Row(
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
    );
  }
}

