import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../services/auth_service.dart';
import '../../../theme/app_theme.dart';
import '../../ds/ds.dart';
import '../wizard_nav.dart';
import '../wizard_step_scaffold.dart';

enum _Target { cloud, selfHosted, localDev }

class DaemonStep extends StatefulWidget {
  const DaemonStep({super.key});

  @override
  State<DaemonStep> createState() => _DaemonStepState();
}

class _DaemonStepState extends State<DaemonStep> {
  _Target _target = _Target.localDev;
  late final TextEditingController _urlCtrl;
  _TestState _test = _TestState.idle;
  String? _testMessage;
  String? _daemonVersion;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(
      text: AuthService().baseUrl,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WizardNav.of(context).setCanAdvance(true);
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  String get _effectiveUrl {
    switch (_target) {
      case _Target.cloud:
        return 'https://cloud.digitorn.dev';
      case _Target.selfHosted:
        return _urlCtrl.text.trim();
      case _Target.localDev:
        return 'http://127.0.0.1:8000';
    }
  }

  Future<void> _runTest() async {
    setState(() {
      _test = _TestState.loading;
      _testMessage = null;
      _daemonVersion = null;
    });
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 4),
        validateStatus: (s) => s != null && s < 500,
      ));
      final r = await dio.get('$_effectiveUrl/api/health');
      if (!mounted) return;
      if (r.statusCode != null && r.statusCode! < 400) {
        final data = r.data;
        String? version;
        if (data is Map) {
          version = (data['version'] ?? data['daemon_version'])?.toString();
        }
        setState(() {
          _test = _TestState.ok;
          _testMessage = 'onboarding.bridge_responding'.tr();
          _daemonVersion = version;
        });
      } else {
        setState(() {
          _test = _TestState.fail;
          _testMessage = 'HTTP ${r.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _test = _TestState.fail;
        _testMessage = e is DioException
            ? (e.message ?? 'onboarding.connection_failed'.tr())
            : 'onboarding.connection_failed'.tr();
      });
    }
  }

  void _commitUrl() {
    AuthService().baseUrl = _effectiveUrl;
  }

  @override
  Widget build(BuildContext context) {
    _commitUrl();
    return WizardStepScaffold(
      eyebrow: 'onboarding.step_01'.tr(),
      title: 'onboarding.daemon_title'.tr(),
      subtitle: 'onboarding.daemon_subtitle_long'.tr(),
      nextLabel: 'onboarding.continue'.tr(),
      showSkip: true,
      skipLabel: 'onboarding.set_later'.tr(),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TargetGrid(
            target: _target,
            onChanged: (t) => setState(() {
              _target = t;
              _test = _TestState.idle;
              _testMessage = null;
              _daemonVersion = null;
            }),
          ),
          if (_target == _Target.selfHosted) ...[
            SizedBox(height: DsSpacing.x5),
            DsInput(
              controller: _urlCtrl,
              label: 'onboarding.bridge_url'.tr(),
              leadingIcon: Icons.dns_outlined,
              placeholder: 'onboarding.bridge_url_placeholder'.tr(),
              keyboardType: TextInputType.url,
              onChanged: (_) => setState(() {
                _test = _TestState.idle;
                _testMessage = null;
              }),
            ),
          ],
          SizedBox(height: DsSpacing.x5),
          _StatusRow(
            state: _test,
            message: _testMessage,
            version: _daemonVersion,
            onTest: _runTest,
            disabled: _target == _Target.cloud,
          ),
        ],
      ),
    );
  }
}

enum _TestState { idle, loading, ok, fail }

class _TargetGrid extends StatelessWidget {
  final _Target target;
  final ValueChanged<_Target> onChanged;
  const _TargetGrid({required this.target, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final compact = DsBreakpoint.isCompact(context);
    final items = [
      _TargetItem(
        value: _Target.cloud,
        title: 'onboarding.target_cloud'.tr(),
        subtitle: 'onboarding.target_cloud_sub'.tr(),
        icon: Icons.cloud_outlined,
        badge: 'onboarding.target_soon'.tr(),
        disabled: true,
      ),
      _TargetItem(
        value: _Target.selfHosted,
        title: 'onboarding.target_self'.tr(),
        subtitle: 'onboarding.target_self_sub'.tr(),
        icon: Icons.lan_outlined,
      ),
      _TargetItem(
        value: _Target.localDev,
        title: 'onboarding.target_local'.tr(),
        subtitle: 'onboarding.target_local_sub'.tr(),
        icon: Icons.laptop_outlined,
      ),
    ];
    if (compact) {
      return Column(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(height: DsSpacing.x3),
            _TargetCard(
              item: items[i],
              selected: target == items[i].value,
              onTap: items[i].disabled ? null : () => onChanged(items[i].value),
            ),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(width: DsSpacing.x3),
          Expanded(
            child: _TargetCard(
              item: items[i],
              selected: target == items[i].value,
              onTap: items[i].disabled ? null : () => onChanged(items[i].value),
            ),
          ),
        ],
      ],
    );
  }
}

class _TargetItem {
  final _Target value;
  final String title;
  final String subtitle;
  final IconData icon;
  final String? badge;
  final bool disabled;
  const _TargetItem({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.badge,
    this.disabled = false,
  });
}

class _TargetCard extends StatelessWidget {
  final _TargetItem item;
  final bool selected;
  final VoidCallback? onTap;
  const _TargetCard({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Opacity(
      opacity: item.disabled ? 0.5 : 1.0,
      child: DsCard(
        selected: selected,
        onTap: onTap,
        padding: EdgeInsets.all(DsSpacing.x5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: selected
                        ? c.accentPrimary.withValues(alpha: 0.14)
                        : c.surfaceAlt,
                    borderRadius: BorderRadius.circular(DsRadius.xs),
                  ),
                  child: Icon(
                    item.icon,
                    size: 16,
                    color: selected ? c.accentPrimary : c.text,
                  ),
                ),
                const Spacer(),
                if (item.badge != null)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: DsSpacing.x3,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.accentSecondary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(DsRadius.pill),
                      border: Border.all(
                        color: c.accentSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      item.badge!,
                      style: DsType.micro(color: c.accentSecondary),
                    ),
                  ),
              ],
            ),
            SizedBox(height: DsSpacing.x4),
            Text(item.title, style: DsType.h3(color: c.textBright)),
            SizedBox(height: DsSpacing.x1),
            Text(
              item.subtitle,
              style: DsType.micro(color: c.textMuted)
                  .copyWith(height: 1.45, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final _TestState state;
  final String? message;
  final String? version;
  final VoidCallback onTest;
  final bool disabled;

  const _StatusRow({
    required this.state,
    required this.message,
    required this.version,
    required this.onTest,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Color dotColor;
    String dotLabel;
    switch (state) {
      case _TestState.idle:
        dotColor = c.textDim;
        dotLabel = 'onboarding.status_not_tested'.tr();
        break;
      case _TestState.loading:
        dotColor = c.accentSecondary;
        dotLabel = 'onboarding.status_reaching'.tr();
        break;
      case _TestState.ok:
        dotColor = c.green;
        dotLabel = version != null
            ? 'onboarding.status_connected_version'
                .tr(namedArgs: {'v': version!})
            : (message ?? 'onboarding.status_connected'.tr());
        break;
      case _TestState.fail:
        dotColor = c.red;
        dotLabel = message ?? 'onboarding.connection_failed'.tr();
        break;
    }
    return Row(
      children: [
        _Dot(color: dotColor, pulsing: state == _TestState.loading),
        SizedBox(width: DsSpacing.x3),
        Expanded(
          child: Text(
            dotLabel,
            style: DsType.caption(color: c.text),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(width: DsSpacing.x3),
        DsButton(
          label: state == _TestState.loading
              ? 'onboarding.testing'.tr()
              : 'onboarding.test_connection'.tr(),
          variant: DsButtonVariant.secondary,
          size: DsButtonSize.sm,
          loading: state == _TestState.loading,
          leadingIcon: Icons.bolt_outlined,
          onPressed: disabled ? null : onTest,
        ),
      ],
    );
  }
}

class _Dot extends StatefulWidget {
  final Color color;
  final bool pulsing;
  const _Dot({required this.color, required this.pulsing});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.pulsing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Dot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.pulsing && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = widget.pulsing ? 0.6 + 0.4 * _c.value : 1.0;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: t),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.5 * t),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}
