import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/preferences_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

class AccessibilityStep extends StatefulWidget {
  const AccessibilityStep({super.key});

  @override
  State<AccessibilityStep> createState() => _AccessibilityStepState();
}

class _AccessibilityStepState extends State<AccessibilityStep> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WizardNav.of(context).setCanAdvance(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final prefs = PreferencesService();
    return ListenableBuilder(
      listenable: prefs,
      builder: (_, _) {
        return WizardStepScaffold(
          eyebrow: 'STEP 03',
          title: 'Adjust for comfort.',
          subtitle:
              'Fine-tune UI density to match how much info you want on screen. '
              'You can revisit this under Settings.',
          nextLabel: 'Finish setup',
          nextIcon: Icons.check,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Label(label: 'DENSITY', c: c),
              SizedBox(height: DsSpacing.x4),
              _DensityPicker(
                value: prefs.density,
                onChanged: (v) => prefs.setDensity(v),
              ),
              SizedBox(height: DsSpacing.x7),
              _PreviewCard(density: prefs.density),
            ],
          ),
        );
      },
    );
  }
}

class _Label extends StatelessWidget {
  final String label;
  final AppColors c;
  const _Label({required this.label, required this.c});

  @override
  Widget build(BuildContext context) =>
      Text(label, style: DsType.eyebrow(color: c.textMuted));
}

class _DensityPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _DensityPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const items = [
      _DensityOpt('compact', 'Compact', 'Max info density'),
      _DensityOpt('comfortable', 'Comfortable', 'Balanced (default)'),
      _DensityOpt('spacious', 'Spacious', 'Easier on the eyes'),
    ];
    return Row(
      children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(width: DsSpacing.x3),
          Expanded(
            child: DsCard(
              selected: value == items[i].id,
              onTap: () => onChanged(items[i].id),
              padding: EdgeInsets.all(DsSpacing.x4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    items[i].title,
                    style: DsType.h3(
                      color: context.colors.textBright,
                    ),
                  ),
                  SizedBox(height: DsSpacing.x1),
                  Text(
                    items[i].desc,
                    style: DsType.micro(
                      color: context.colors.textMuted,
                    ).copyWith(fontSize: 11.5, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _DensityOpt {
  final String id;
  final String title;
  final String desc;
  const _DensityOpt(this.id, this.title, this.desc);
}

class _PreviewCard extends StatelessWidget {
  final String density;
  const _PreviewCard({required this.density});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rowPad = switch (density) {
      'compact' => 8.0,
      'spacious' => 16.0,
      _ => 12.0,
    };
    final rowGap = switch (density) {
      'compact' => 4.0,
      'spacious' => 10.0,
      _ => 6.0,
    };
    return DsSurface(
      padding: EdgeInsets.all(DsSpacing.x5),
      elevation: DsSurfaceElevation.raise,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PREVIEW', style: DsType.eyebrow(color: c.textMuted)),
          SizedBox(height: DsSpacing.x4),
          for (int i = 0; i < 4; i++) ...[
            if (i > 0) SizedBox(height: rowGap),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: rowPad,
              ),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(DsRadius.xs),
              ),
              child: Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: c.accentPrimary.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: c.textMuted.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  SizedBox(width: 10),
                  Container(
                    width: 30,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.textMuted.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
