import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import '../../models/app_summary.dart';
import '../../services/api_client.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import 'app_health.dart';

class AppSelector extends StatefulWidget {
  final Function(AppSummary) onAppSelected;

  const AppSelector({super.key, required this.onAppSelected});

  @override
  State<AppSelector> createState() => _AppSelectorState();
}

class _AppSelectorState extends State<AppSelector> {
  List<AppSummary> apps = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchApps();
  }

  Future<void> _deployApp() async {
    final result = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'YAML', extensions: ['yaml', 'yml']),
      ],
    );
    if (result == null) return;

    setState(() => isLoading = true);
    try {
      final auth = AuthService();
      final dio = Dio()..interceptors.add(auth.authInterceptor);
      final resp = await dio.post(
        '${auth.baseUrl}/api/apps/deploy',
        data: {'yaml_path': result.path, 'force': true},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (resp.data?['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deployed: ${resp.data['data']?['name'] ?? 'app'}'),
              backgroundColor: context.colors.green.withValues(alpha: 0.1),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deploy failed: ${resp.data?['error'] ?? 'unknown'}'),
              backgroundColor: context.colors.red.withValues(alpha: 0.1),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Deploy error: $e');
    }
    _fetchApps();
  }

  Future<void> _fetchApps() async {
    final auth = AuthService();
    // Ensure token is fresh before fetching
    await auth.ensureValidToken();
    final client = DigitornApiClient()
      ..updateBaseUrl(auth.baseUrl, token: auth.accessToken);
    final fetched = await client.fetchApps();
    if (mounted) {
      setState(() {
        apps = fetched;
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 1.5, color: context.colors.textDim));
    }

    if (apps.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                color: context.colors.surfaceAlt,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.colors.border),
              ),
              child: Icon(Icons.rocket_launch_outlined, color: context.colors.textMuted, size: 26),
            ),
            const SizedBox(height: 20),
            Text(
              'No apps deployed yet',
              style: GoogleFonts.inter(
                fontSize: 18, fontWeight: FontWeight.w600, color: context.colors.text),
            ),
            const SizedBox(height: 10),
            Text(
              'Deploy an app on your Digitorn daemon to get started.\n\nFrom the CLI:\n',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(color: context.colors.textMuted, fontSize: 13, height: 1.6),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.colors.codeBlockBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.colors.border),
              ),
              child: SelectableText(
                'digitorn deploy examples/chat.yaml',
                style: GoogleFonts.firaCode(fontSize: 13, color: context.colors.text),
              ),
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() => isLoading = true);
                    _fetchApps();
                  },
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.colors.surfaceAlt,
                    foregroundColor: context.colors.text,
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () => AuthService().logout(),
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('Logout'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.colors.textMuted,
                    side: BorderSide(color: context.colors.border),
                  ),
                ),
              ],
            ),
          ],
        ),
        ),
      );
    }

    return Container(
      color: context.colors.bg,
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Dashboard',
                    style: GoogleFonts.inter(fontSize: 26, fontWeight: FontWeight.w700, color: context.colors.textBright),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Select an application to start',
                    style: GoogleFonts.inter(fontSize: 14, color: context.colors.textMuted),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.upload_file_rounded, color: context.colors.textMuted),
                    onPressed: _deployApp,
                    tooltip: 'Deploy app (YAML)',
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.refresh, color: context.colors.textMuted),
                    onPressed: () {
                      setState(() => isLoading = true);
                      _fetchApps();
                    },
                    tooltip: 'Refresh',
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.logout, color: context.colors.textMuted),
                    onPressed: () => AuthService().logout(),
                    tooltip: 'Logout',
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 32),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 320,
                childAspectRatio: 1.5,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: apps.length,
              itemBuilder: (context, index) {
                final app = apps[index];
                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 300 + index * 50),
                  curve: Curves.easeOut,
                  builder: (_, value, child) => Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 12 * (1 - value)),
                      child: child,
                    ),
                  ),
                  child: AppCard(
                    app: app,
                    onTap: () => widget.onAppSelected(app),
                  ),
                );
              },
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class AppCard extends StatefulWidget {
  final AppSummary app;
  final VoidCallback onTap;

  const AppCard({super.key, required this.app, required this.onTap});

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: _hovered ? context.colors.surfaceAlt : context.colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered ? context.colors.borderHover : context.colors.border,
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      widget.app.name,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.colors.textBright,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.colors.border,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: context.colors.borderHover),
                    ),
                    child: Text(
                      "v${widget.app.version}",
                      style: GoogleFonts.inter(fontSize: 10, color: context.colors.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                widget.app.agents.isEmpty
                    ? 'No agents'
                    : widget.app.agents.join(' · '),
                style: GoogleFonts.inter(fontSize: 12, color: context.colors.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.build_outlined, size: 13, color: context.colors.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.app.totalTools}',
                    style: GoogleFonts.inter(fontSize: 12, color: context.colors.textMuted),
                  ),
                  const SizedBox(width: 12),
                  Icon(Icons.layers_outlined, size: 13, color: context.colors.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.app.totalCategories}',
                    style: GoogleFonts.inter(fontSize: 12, color: context.colors.textMuted),
                  ),
                  const Spacer(),
                  AnimatedOpacity(
                    opacity: _hovered ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () => AppHealthDialog.show(
                              context, widget.app.appId, widget.app.name),
                          child: Icon(Icons.monitor_heart_outlined,
                              size: 14, color: context.colors.textDim),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.arrow_forward_rounded,
                            size: 14, color: context.colors.textDim),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
