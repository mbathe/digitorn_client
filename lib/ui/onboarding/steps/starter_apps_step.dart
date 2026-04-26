import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/onboarding_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

class StarterAppsStep extends StatefulWidget {
  const StarterAppsStep({super.key});

  @override
  State<StarterAppsStep> createState() => _StarterAppsStepState();
}

class _StarterAppsStepState extends State<StarterAppsStep> {
  // Pre-checked by default on first visit. Builder + Chat are the
  // two apps every user actually uses — skipping them means the
  // Hub is empty after Finish. Users can uncheck Chat if they
  // really don't want it; Builder stays mandatory.
  static const Set<String> _defaultSelection = {
    'digitorn-builder',
    'digitorn-chat',
  };

  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _selected.addAll(OnboardingService().installedApps);
    if (_selected.isEmpty) _selected.addAll(_defaultSelection);
    // Builder is pre-installed — always part of the runtime.
    _selected.add('digitorn-builder');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncOut();
      WizardNav.of(context).setCanAdvance(true);
    });
  }

  void _syncOut() {
    OnboardingService().installedApps
      ..clear()
      ..addAll(_selected);
  }

  void _toggle(String id) {
    if (id == 'digitorn-builder') return; // builder is mandatory
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      _syncOut();
    });
  }

  @override
  Widget build(BuildContext context) {
    final apps = _starterApps();
    final count = _selected.length;
    return WizardStepScaffold(
      eyebrow: 'STEP 03',
      title: 'Your first apps.',
      subtitle:
          'Builder ships pre-installed so you can create your own apps right '
          'away. Add a few from the Hub to get started — browse thousands '
          'more once you are in.',
      showSkip: true,
      skipLabel: 'Skip the Hub',
      nextLabel: count > 1 ? 'Install $count apps' : 'Install & continue',
      maxWidth: 760,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader(
            label: 'BUILD YOUR OWN',
            trailing: 'PRE-INSTALLED',
          ),
          SizedBox(height: DsSpacing.x4),
          const _BuilderFeatureCard(),
          SizedBox(height: DsSpacing.x8),
          const _SectionHeader(
            label: 'INSTALL FROM THE HUB',
            trailing: '6 curated for you',
          ),
          SizedBox(height: DsSpacing.x4),
          // LayoutBuilder so the card row adapts to the available
          // space — on compact screens we get a single-column stack
          // where cards fill the row, on wide screens the Wrap flows
          // 2-3 cards per row as designed. A fixed 240 px child
          // inside a 200 px wide parent used to RenderFlex-overflow
          // the wizard column on narrow windows.
          LayoutBuilder(builder: (ctx, constraints) {
            final w = constraints.maxWidth;
            if (w < 260) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final a in apps) ...[
                    _AppCard(
                      app: a,
                      selected: _selected.contains(a.id),
                      onTap: () => _toggle(a.id),
                    ),
                    SizedBox(height: DsSpacing.x3),
                  ],
                ],
              );
            }
            return Wrap(
              spacing: DsSpacing.x3,
              runSpacing: DsSpacing.x3,
              children: [
                for (final a in apps)
                  SizedBox(
                    width: 240,
                    child: _AppCard(
                      app: a,
                      selected: _selected.contains(a.id),
                      onTap: () => _toggle(a.id),
                    ),
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final String? trailing;
  const _SectionHeader({required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Text(label, style: DsType.eyebrow(color: c.accentPrimary)),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: DsSpacing.x4),
            child: Container(height: 1, color: c.border),
          ),
        ),
        if (trailing != null)
          Text(trailing!, style: DsType.eyebrow(color: c.textDim)),
      ],
    );
  }
}

/// The hero card — Digitorn Builder, always included. Shows a faux
/// chat input that rotates through example prompts so users
/// immediately grok what Builder does.
class _BuilderFeatureCard extends StatelessWidget {
  const _BuilderFeatureCard();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.surface,
            Color.lerp(c.surface, c.accentPrimary, 0.08) ?? c.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(DsRadius.card),
        border: Border.all(
          color: c.accentPrimary.withValues(alpha: 0.4),
          width: DsStroke.normal,
        ),
        boxShadow: DsElevation.accentGlow(c.accentPrimary, strength: 0.35),
      ),
      padding: EdgeInsets.all(DsSpacing.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [c.accentPrimary, c.accentSecondary],
                  ),
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                  boxShadow: DsElevation.accentGlow(c.accentPrimary,
                      strength: 0.6),
                ),
                child: Icon(
                  Icons.auto_fix_high,
                  color: c.onAccent,
                  size: 20,
                ),
              ),
              SizedBox(width: DsSpacing.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: DsSpacing.x3,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('Digitorn Builder',
                            style: DsType.h2(color: c.textBright)),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: DsSpacing.x3,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: c.accentPrimary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(DsRadius.pill),
                            border: Border.all(
                              color: c.accentPrimary.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            'INCLUDED',
                            style: DsType.micro(color: c.accentPrimary)
                                .copyWith(
                              letterSpacing: 1.2,
                              fontWeight: FontWeight.w700,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Tell Builder what you want — it ships you an app.',
                      style: DsType.caption(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: DsSpacing.x5),
          const _BuilderPromptDemo(),
        ],
      ),
    );
  }
}

class _BuilderPromptDemo extends StatefulWidget {
  const _BuilderPromptDemo();

  @override
  State<_BuilderPromptDemo> createState() => _BuilderPromptDemoState();
}

class _BuilderPromptDemoState extends State<_BuilderPromptDemo>
    with SingleTickerProviderStateMixin {
  static const _prompts = [
    'Build me a PR reviewer that summarises each file change…',
    'Create an inbox triager that tags emails by urgency…',
    'Make an agent that drafts weekly updates from my commits…',
    'Spin up a data explorer over this Postgres database…',
    'Build me a meeting summariser with action items…',
  ];

  int _promptIndex = 0;
  int _charCount = 0;
  bool _deleting = false;
  Timer? _tick;
  late final AnimationController _cursor;

  @override
  void initState() {
    super.initState();
    _cursor = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _tick = Timer.periodic(const Duration(milliseconds: 36), (_) => _step());
  }

  void _step() {
    if (!mounted) return;
    final current = _prompts[_promptIndex];
    setState(() {
      if (!_deleting) {
        if (_charCount < current.length) {
          _charCount++;
        } else {
          _deleting = true;
          _tick?.cancel();
          Future.delayed(const Duration(milliseconds: 2200), () {
            if (!mounted) return;
            _tick = Timer.periodic(
                const Duration(milliseconds: 16), (_) => _step());
          });
        }
      } else {
        if (_charCount > 0) {
          _charCount--;
        } else {
          _deleting = false;
          _promptIndex = (_promptIndex + 1) % _prompts.length;
        }
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = _prompts[_promptIndex].substring(0, _charCount);
    final baseStyle = DsType.body(color: c.textBright);
    return Container(
      decoration: BoxDecoration(
        color: c.inputBg,
        borderRadius: BorderRadius.circular(DsRadius.input),
        border: Border.all(color: c.inputBorder),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: DsSpacing.x4,
        vertical: DsSpacing.x4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: c.accentPrimary.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.north,
              size: 12,
              color: c.accentPrimary,
            ),
          ),
          SizedBox(width: DsSpacing.x3),
          Expanded(
            // Text.rich gives proper text-level line-wrapping. The
            // previous ``Wrap`` implementation treated the whole text
            // as ONE widget child, so as the typed prompt grew
            // character-by-character the widget expanded past the
            // available width and RenderFlex overflowed by ~100 k px
            // (the "99907 pixels on the right" the step 3 crash log
            // shows). ``WidgetSpan`` lets the blinking cursor flow
            // inline with the text, moving to the next line
            // naturally as the prompt wraps.
            child: Text.rich(
              TextSpan(
                style: baseStyle,
                children: [
                  TextSpan(text: text),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: AnimatedBuilder(
                      animation: _cursor,
                      builder: (_, _) => Opacity(
                        opacity: _cursor.value > 0.5 ? 1 : 0,
                        child: Container(
                          margin: const EdgeInsets.only(left: 1),
                          width: 2,
                          height: 16,
                          color: c.accentPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _StarterApp {
  final String id;
  final String name;
  final String desc;
  final IconData icon;
  const _StarterApp(this.id, this.name, this.desc, this.icon);
}

/// The curated starter-app list.
///
/// Every ID here MUST match a real builtin bundle the daemon can
/// resolve via ``POST /api/apps/install`` with
/// ``sourceType: 'builtin'`` and the ID as ``sourceUri``.
/// Previously this list mixed fictional IDs
/// like ``code-review`` / ``shell-agent`` that 404-ed on install
/// — confusing users into thinking the onboarding was broken.
/// These IDs live under ``packages/digitorn/builtins/`` on the
/// daemon and ship with every release.
List<_StarterApp> _starterApps() {
  return const [
    _StarterApp('digitorn-chat', 'Chat',
        'General-purpose chat with any model.', Icons.chat_outlined),
    _StarterApp('digitorn-code', 'Code',
        'Coding agent with workspace + terminal.', Icons.code),
    _StarterApp('digitorn-deepresearch', 'Deep Research',
        'Multi-source reading + synthesis.', Icons.menu_book_outlined),
    _StarterApp('digitorn-react-sandbox', 'React Sandbox',
        'Live-preview React playground.', Icons.web_asset_outlined),
  ];
}

class _AppCard extends StatelessWidget {
  final _StarterApp app;
  final bool selected;
  final VoidCallback onTap;
  const _AppCard({
    required this.app,
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: selected
                  ? c.accentPrimary.withValues(alpha: 0.14)
                  : c.surfaceAlt,
              borderRadius: BorderRadius.circular(DsRadius.xs),
            ),
            child: Icon(
              app.icon,
              size: 18,
              color: selected ? c.accentPrimary : c.text,
            ),
          ),
          SizedBox(width: DsSpacing.x4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        app.name,
                        style: DsType.h3(color: c.textBright),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    AnimatedContainer(
                      duration: DsDuration.fast,
                      curve: DsCurve.decelSnap,
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: selected ? c.accentPrimary : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: selected ? c.accentPrimary : c.border,
                        ),
                      ),
                      child: selected
                          ? Icon(Icons.check, size: 10, color: c.onAccent)
                          : null,
                    ),
                  ],
                ),
                SizedBox(height: DsSpacing.x1),
                Text(
                  app.desc,
                  style: DsType.micro(color: c.textMuted)
                      .copyWith(fontSize: 11.5, height: 1.4),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
