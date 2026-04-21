/// "Hub" — single top-level surface that hosts the three extension
/// points the daemon exposes: Apps (packages), Modules (python
/// bundles shipped with the wheel) and MCP servers (out-of-process
/// tool providers). Reachable from BOTH the activity-bar sidebar
/// and the Settings sidebar so users can find it whichever mental
/// model they bring.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../mcp/mcp_store_page.dart';
import '../packages/modules_view.dart';
import '../packages/packages_store_page.dart';

class HubPage extends StatefulWidget {
  /// True when hosted inside the Settings shell — drops the back
  /// button (settings already has its own sidebar nav) and uses
  /// the section's parent background instead of standalone chrome.
  final bool embedded;
  const HubPage({super.key, this.embedded = false});

  @override
  State<HubPage> createState() => _HubPageState();
}

class _HubPageState extends State<HubPage>
    with TickerProviderStateMixin {
  int _active = 0;
  late final AnimationController _entry;

  List<_HubTab> get _tabs => [
        _HubTab(
          label: 'hub.tab_apps'.tr(),
          hint: 'hub.tab_apps_hint'.tr(),
          icon: Icons.apps_rounded,
        ),
        _HubTab(
          label: 'hub.tab_modules'.tr(),
          hint: 'hub.tab_modules_hint'.tr(),
          icon: Icons.extension_outlined,
        ),
        _HubTab(
          label: 'hub.tab_mcp'.tr(),
          hint: 'hub.tab_mcp_hint'.tr(),
          icon: Icons.electrical_services_rounded,
        ),
      ];

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward();
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  Widget _buildBody(int index) {
    switch (index) {
      case 0:
        return const PackagesStorePage(
          embedded: true,
          hideModulesTab: true,
          hideHeader: true,
        );
      case 1:
        return const ModulesView();
      case 2:
        return const McpStorePage(embedded: true, hideHeader: true);
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final body = Column(
      children: [
        _HubHeader(
          entry: _entry,
          embedded: widget.embedded,
          tabs: _tabs,
          active: _active,
          onSelect: (i) => setState(() => _active = i),
        ),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey(_active),
            child: _buildBody(_active),
          ),
        ),
      ],
    );
    if (widget.embedded) {
      return Container(color: c.bg, child: body);
    }
    return Scaffold(backgroundColor: c.bg, body: body);
  }
}

class _HubTab {
  final String label;
  final String hint;
  final IconData icon;
  const _HubTab({
    required this.label,
    required this.hint,
    required this.icon,
  });
}

class _HubHeader extends StatelessWidget {
  final AnimationController entry;
  final bool embedded;
  final List<_HubTab> tabs;
  final int active;
  final ValueChanged<int> onSelect;

  const _HubHeader({
    required this.entry,
    required this.embedded,
    required this.tabs,
    required this.active,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final canPop = !embedded && Navigator.canPop(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.surface,
            Color.lerp(c.surface, c.accentPrimary, 0.03) ?? c.surface,
          ],
        ),
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: AnimatedBuilder(
        animation: entry,
        builder: (_, child) {
          final t = Curves.easeOutCubic.transform(entry.value);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 6),
              child: child,
            ),
          );
        },
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              canPop ? 16 : 44, 26, 44, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (canPop) ...[
                    _BackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 10),
                  ],
                  _HeroIcon(icon: Icons.extension_rounded),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'hub.title'.tr(),
                          style: GoogleFonts.inter(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: c.textBright,
                            letterSpacing: -0.6,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'hub.subtitle'.tr(),
                          style: GoogleFonts.inter(
                            fontSize: 14.5,
                            color: c.textMuted,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              _PillTabBar(
                tabs: tabs,
                active: active,
                onSelect: onSelect,
              ),
              const SizedBox(height: 0),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackButton extends StatefulWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});
  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : null,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: _h ? c.border : Colors.transparent),
          ),
          child: Icon(Icons.arrow_back_rounded,
              size: 16, color: _h ? c.textBright : c.textMuted),
        ),
      ),
    );
  }
}

class _HeroIcon extends StatelessWidget {
  final IconData icon;
  const _HeroIcon({required this.icon});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 50,
      height: 50,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.accentPrimary, c.accentSecondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: c.glow.withValues(alpha: 0.35),
            blurRadius: 16,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(icon, size: 24, color: c.onAccent),
    );
  }
}

class _PillTabBar extends StatelessWidget {
  final List<_HubTab> tabs;
  final int active;
  final ValueChanged<int> onSelect;
  const _PillTabBar({
    required this.tabs,
    required this.active,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < tabs.length; i++)
          _PillTab(
            tab: tabs[i],
            active: i == active,
            onTap: () => onSelect(i),
          ),
      ],
    );
  }
}

class _PillTab extends StatefulWidget {
  final _HubTab tab;
  final bool active;
  final VoidCallback onTap;
  const _PillTab({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  @override
  State<_PillTab> createState() => _PillTabState();
}

class _PillTabState extends State<_PillTab> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = widget.active;
    return Tooltip(
      message: widget.tab.hint,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              gradient: active
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [c.accentPrimary, c.accentSecondary],
                    )
                  : null,
              color: active
                  ? null
                  : (_h ? c.surfaceAlt : c.surface),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active
                    ? Colors.transparent
                    : (_h ? c.borderHover : c.border),
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: c.glow.withValues(alpha: 0.42),
                        blurRadius: 18,
                        spreadRadius: -4,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.tab.icon,
                  size: 16,
                  color: active
                      ? c.onAccent
                      : (_h ? c.textBright : c.text),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.tab.label,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight:
                        active ? FontWeight.w700 : FontWeight.w600,
                    color: active
                        ? c.onAccent
                        : (_h ? c.textBright : c.text),
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
