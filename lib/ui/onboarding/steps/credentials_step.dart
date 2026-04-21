import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/onboarding_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

class CredentialsStep extends StatefulWidget {
  const CredentialsStep({super.key});

  @override
  State<CredentialsStep> createState() => _CredentialsStepState();
}

class _CredentialsStepState extends State<CredentialsStep> {
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _selected.addAll(OnboardingService().connectedProviders);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WizardNav.of(context).setCanAdvance(true);
    });
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      OnboardingService().connectedProviders
        ..clear()
        ..addAll(_selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    const providers = [
      _Provider('anthropic', 'Anthropic', 'Claude — flagship reasoning.',
          Color(0xFFCC785C)),
      _Provider('openai', 'OpenAI', 'GPT — broadly capable.',
          Color(0xFF10A37F)),
      _Provider('google', 'Google', 'Gemini — multimodal native.',
          Color(0xFF4285F4)),
      _Provider('mistral', 'Mistral', 'Open weights, fast.',
          Color(0xFFFF7000)),
      _Provider('groq', 'Groq', 'Lowest-latency hosted.',
          Color(0xFFF55036)),
      _Provider('ollama', 'Ollama', 'Local models, zero cloud.',
          Color(0xFF8D8D8D)),
    ];
    return WizardStepScaffold(
      eyebrow: 'STEP 02',
      title: 'Bring your models.',
      subtitle:
          'Pick the AI providers you use. You can add credentials now or '
          'later — we only ask when you launch an app that needs them.',
      showSkip: true,
      skipLabel: 'Skip for now',
      maxWidth: 720,
      content: Wrap(
        spacing: DsSpacing.x3,
        runSpacing: DsSpacing.x3,
        children: [
          for (final p in providers)
            SizedBox(
              width: 220,
              child: _ProviderCard(
                provider: p,
                selected: _selected.contains(p.id),
                onTap: () => _toggle(p.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _Provider {
  final String id;
  final String name;
  final String desc;
  final Color tint;
  const _Provider(this.id, this.name, this.desc, this.tint);
}

class _ProviderCard extends StatelessWidget {
  final _Provider provider;
  final bool selected;
  final VoidCallback onTap;
  const _ProviderCard({
    required this.provider,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DsCard(
      selected: selected,
      onTap: onTap,
      padding: EdgeInsets.all(DsSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: provider.tint
                      .withValues(alpha: selected ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                ),
                child: Center(
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: provider.tint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              AnimatedContainer(
                duration: DsDuration.fast,
                curve: DsCurve.decelSnap,
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: selected ? c.accentPrimary : Colors.transparent,
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                  border: Border.all(
                    color: selected ? c.accentPrimary : c.border,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check, size: 12, color: c.onAccent)
                    : null,
              ),
            ],
          ),
          SizedBox(height: DsSpacing.x4),
          Text(provider.name, style: DsType.h3(color: c.textBright)),
          SizedBox(height: DsSpacing.x1),
          Text(
            provider.desc,
            style: DsType.micro(color: c.textMuted)
                .copyWith(fontSize: 11.5, height: 1.4),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
