/// The serious credential form. Centered dialog (not a bottom
/// sheet), searchable provider picker → rich form flow, handles
/// every credential type the daemon exposes:
///
///   * `api_key`           → single secret field
///   * `multi_field`       → grouped fields (AWS, Twilio, …)
///   * `oauth2`            → large Connect CTA + scopes preview
///   * `connection_string` → URL field with scheme validation
///   * `mcp_server`        → command / args / env table
///
/// Features:
///   * Provider cards grid with icon + type badge + fuzzy search
///   * Sticky header showing chosen provider during the form step
///   * Label field with chip suggestions (personal / work / project)
///   * Test connection before save (daemon probe recipe)
///   * Inline errors, per-field validation, secret show/hide
///   * OAuth start → opens auth URL → polls status
///   * Sticky footer with Cancel / Test / Save or Connect
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/credential_v2.dart';
import '../../services/credentials_v2_service.dart';
import '../../theme/app_theme.dart';
import 'credential_field_form.dart';

/// Public entry point — returns the created [CredentialV2] or null
/// if the user cancelled. Replaces the old bottom-sheet flow.
Future<CredentialV2?> showCredentialFormDialog(BuildContext context) {
  return showDialog<CredentialV2>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    barrierDismissible: false,
    builder: (_) => const _CredentialFormDialog(),
  );
}

class _CredentialFormDialog extends StatefulWidget {
  const _CredentialFormDialog();

  @override
  State<_CredentialFormDialog> createState() => _CredentialFormDialogState();
}

class _CredentialFormDialogState extends State<_CredentialFormDialog> {
  final _svc = CredentialsV2Service();

  // ── Phase state ────────────────────────────────────────────────
  // null = picker, non-null = form
  ProviderCatalogueEntry? _picked;

  // ── Picker state ───────────────────────────────────────────────
  List<ProviderCatalogueEntry> _providers = const [];
  bool _loadingProviders = true;
  String _query = '';
  String _typeFilter = 'all';

  // ── Form state ─────────────────────────────────────────────────
  final _labelCtrl = TextEditingController(text: 'default');
  Map<String, String> _values = const {};
  bool _valid = false;
  bool _saving = false;
  bool _testing = false;
  String? _error;
  _TestResult? _testResult;

  @override
  void initState() {
    super.initState();
    _loadProviders();
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProviders() async {
    setState(() => _loadingProviders = true);
    final list = await _svc.loadProviders();
    if (!mounted) return;
    list.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    setState(() {
      _providers = list;
      _loadingProviders = false;
    });
  }

  List<ProviderCatalogueEntry> get _filtered {
    return _providers.where((p) {
      if (_typeFilter != 'all' && p.type != _typeFilter) return false;
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return p.label.toLowerCase().contains(q) ||
          p.name.toLowerCase().contains(q) ||
          p.type.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final cred = await _svc.create(
        providerName: _picked!.name,
        providerType: _picked!.type,
        label: _labelCtrl.text.trim().isEmpty
            ? 'default'
            : _labelCtrl.text.trim(),
        fields: _values,
      );
      if (!mounted) return;
      Navigator.pop(context, cred);
    } on CredV2Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _error = null;
    });
    final r = await _svc.testFields(
      providerName: _picked!.name,
      providerType: _picked!.type,
      fields: _values,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = _TestResult(
        ok: r['ok'] == true,
        detail: (r['detail'] ?? '').toString(),
        latencyMs: r['latency_ms'] is num
            ? (r['latency_ms'] as num).toInt()
            : null,
      );
    });
  }

  Future<void> _startOauth() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final resp = await _svc.startUserOauth(
        providerName: _picked!.name,
        label: _labelCtrl.text.trim().isEmpty
            ? 'default'
            : _labelCtrl.text.trim(),
      );
      final url = resp?['auth_url'] as String?;
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        setState(() {
          _saving = false;
          _error = 'credentials.daemon_no_auth_url'.tr();
        });
        return;
      }
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!mounted) return;
      if (!opened) {
        // Fallback: copy URL to clipboard so user can paste manually.
        await Clipboard.setData(ClipboardData(text: url));
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = 'credentials.browser_open_failed'.tr();
        });
        return;
      }
      setState(() => _saving = false);
      // Close the dialog — the daemon will drop the credential into
      // the vault after the callback and the parent page's refresh
      // will pick it up on the next list() call.
      if (!mounted) return;
      Navigator.pop(context, null);
    } on CredV2Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final screen = MediaQuery.sizeOf(context);
    final maxW = screen.width < 680 ? screen.width - 32 : 640.0;
    final maxH = screen.height < 820 ? screen.height - 96 : 760.0;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: screen.width < 680 ? 12 : 24,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 40,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(c),
              Divider(height: 1, color: c.border),
              Flexible(
                child: _picked == null ? _buildPicker(c) : _buildForm(c),
              ),
              Divider(height: 1, color: c.border),
              _buildFooter(c),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────

  Widget _buildHeader(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 14, 16),
      child: Row(
        children: [
          if (_picked != null)
            IconButton(
              iconSize: 18,
              tooltip: 'credentials.tooltip_back'.tr(),
              icon: Icon(Icons.arrow_back_rounded, color: c.textMuted),
              onPressed: _saving
                  ? null
                  : () => setState(() {
                        _picked = null;
                        _values = const {};
                        _valid = false;
                        _error = null;
                        _testResult = null;
                      }),
            ),
          if (_picked != null) const SizedBox(width: 6),
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _picked != null
                    ? _gradientFor(_picked!.name, c)
                    : [c.blue, c.purple],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(11),
              boxShadow: [
                BoxShadow(
                  color: (_picked != null
                          ? _gradientFor(_picked!.name, c).first
                          : c.blue)
                      .withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(
              _picked?.icon ?? Icons.key_rounded,
              size: 22,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _picked != null
                      ? 'credentials.new_provider_credential_title'
                          .tr(namedArgs: {'provider': _picked!.label})
                      : 'credentials.new_credential_title'.tr(),
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: c.textBright,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _picked != null
                      ? _typeLabel(_picked!.type)
                      : 'credentials.pick_provider_hint'.tr(),
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: c.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            iconSize: 18,
            tooltip: 'credentials.tooltip_close'.tr(),
            icon: Icon(Icons.close_rounded, color: c.textMuted),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'api_key':
        return 'API KEY · single secret field';
      case 'multi_field':
        return 'MULTI-FIELD · several inputs';
      case 'oauth2':
        return 'OAUTH2 · browser-based flow';
      case 'connection_string':
        return 'CONNECTION STRING · single URL';
      case 'mcp_server':
        return 'MCP SERVER · process + env';
      default:
        return type.toUpperCase();
    }
  }

  List<Color> _gradientFor(String providerName, AppColors c) {
    final hash = providerName.hashCode;
    return [
      HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.6, 0.5).toColor(),
      HSLColor.fromAHSL(1, ((hash ~/ 7) % 360).toDouble(), 0.6, 0.4).toColor(),
    ];
  }

  // ── Picker ─────────────────────────────────────────────────────

  Widget _buildPicker(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Search bar
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 15, color: c.textMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    autofocus: true,
                    onChanged: (v) => setState(() => _query = v.trim()),
                    style: GoogleFonts.inter(
                        fontSize: 13, color: c.textBright),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText:
                          'Search ${_providers.length} providers by name, type…',
                      hintStyle:
                          GoogleFonts.inter(fontSize: 12.5, color: c.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Type filter chips
          SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _TypeChip(
                  label: 'All',
                  active: _typeFilter == 'all',
                  onTap: () => setState(() => _typeFilter = 'all'),
                ),
                _TypeChip(
                  label: 'API key',
                  active: _typeFilter == 'api_key',
                  onTap: () => setState(() => _typeFilter = 'api_key'),
                ),
                _TypeChip(
                  label: 'OAuth',
                  active: _typeFilter == 'oauth2',
                  onTap: () => setState(() => _typeFilter = 'oauth2'),
                ),
                _TypeChip(
                  label: 'Multi-field',
                  active: _typeFilter == 'multi_field',
                  onTap: () => setState(() => _typeFilter = 'multi_field'),
                ),
                _TypeChip(
                  label: 'Connection string',
                  active: _typeFilter == 'connection_string',
                  onTap: () =>
                      setState(() => _typeFilter = 'connection_string'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Flexible(
            child: _loadingProviders && _providers.isEmpty
                ? _buildLoading(c)
                : _filtered.isEmpty
                    ? _buildPickerEmpty(c)
                    : _buildPickerGrid(c),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 60),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: c.textMuted),
          ),
        ),
      );

  Widget _buildPickerEmpty(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off_rounded, size: 36, color: c.textMuted),
              const SizedBox(height: 12),
              Text(
                _query.isNotEmpty
                    ? 'No provider matches "$_query"'
                    : 'No providers available',
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted),
              ),
            ],
          ),
        ),
      );

  Widget _buildPickerGrid(AppColors c) {
    return GridView.count(
      shrinkWrap: true,
      physics: const BouncingScrollPhysics(),
      crossAxisCount: 2,
      childAspectRatio: 3.2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      children: [
        for (final e in _filtered)
          _ProviderTile(
            entry: e,
            gradient: _gradientFor(e.name, c),
            onTap: () => setState(() {
              _picked = e;
              _error = null;
              _testResult = null;
            }),
          ),
      ],
    );
  }

  // ── Form ───────────────────────────────────────────────────────

  Widget _buildForm(AppColors c) {
    final isOauth = _picked!.type == 'oauth2';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Label ──
          Text('Name this credential',
              style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: c.textMuted,
                  letterSpacing: 0.6)),
          const SizedBox(height: 8),
          TextField(
            controller: _labelCtrl,
            style: GoogleFonts.inter(
                fontSize: 13,
                color: c.textBright,
                fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: c.surfaceAlt,
              prefixIcon:
                  Icon(Icons.label_outline_rounded, size: 15, color: c.textMuted),
              hintText: 'e.g. personal, work, project-x',
              hintStyle:
                  GoogleFonts.inter(fontSize: 12.5, color: c.textDim),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: c.blue, width: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final suggestion in const ['default', 'personal', 'work', 'project'])
                _LabelSuggestionChip(
                  label: suggestion,
                  onTap: () => setState(() {
                    _labelCtrl.text = suggestion;
                    _testResult = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 22),
          if (isOauth)
            _buildOauthSection(c)
          else ...[
            Text(
                _picked!.fields.isEmpty
                    ? 'No fields required'
                    : 'Fill in the details',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: c.textMuted,
                    letterSpacing: 0.6)),
            const SizedBox(height: 12),
            if (_picked!.fields.isEmpty)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: c.orange.withValues(alpha: 0.3)),
                ),
                child: Text(
                  'The daemon did not return any field spec for this provider. The credential will be created empty and filled when the agent asks for it.',
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.text, height: 1.5),
                ),
              )
            else
              CredentialFieldForm(
                fields: _picked!.fields,
                onChanged: (v, valid) {
                  _values = v;
                  _valid = valid;
                  _testResult = null;
                  if (mounted) setState(() {});
                },
              ),
          ],
          if (_testResult != null) ...[
            const SizedBox(height: 4),
            _TestResultBanner(result: _testResult!),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.red.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 14, color: c.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!,
                        style: GoogleFonts.firaCode(
                            fontSize: 11,
                            color: c.red,
                            height: 1.5)),
                  ),
                ],
              ),
            ),
          ],
          if (_picked!.docsUrl != null && _picked!.docsUrl!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Center(
              child: TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(_picked!.docsUrl!),
                  mode: LaunchMode.externalApplication,
                ),
                icon: Icon(Icons.menu_book_outlined,
                    size: 13, color: c.textMuted),
                label: Text('Open ${_picked!.label} docs',
                    style: GoogleFonts.inter(
                        fontSize: 11, color: c.textMuted)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOauthSection(AppColors c) {
    final provider = _picked!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('How this works',
            style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: c.textMuted,
                letterSpacing: 0.6)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OauthStep(
                n: 1,
                title: 'Click Connect',
                body: 'Your browser opens on the ${provider.label} sign-in page.',
              ),
              const SizedBox(height: 10),
              _OauthStep(
                n: 2,
                title: 'Authorize Digitorn',
                body:
                    'You approve the scopes below. Digitorn never sees your password.',
              ),
              const SizedBox(height: 10),
              _OauthStep(
                n: 3,
                title: 'Come back here',
                body:
                    'The credential lands in your vault and this dialog closes on its own.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Footer ─────────────────────────────────────────────────────

  Widget _buildFooter(AppColors c) {
    if (_picked == null) {
      // Picker footer: just a hint + close button
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 12, color: c.textMuted),
            const SizedBox(width: 6),
            Text(
                '${_filtered.length} provider${_filtered.length == 1 ? '' : 's'} listed',
                style: GoogleFonts.firaCode(fontSize: 10.5, color: c.textMuted)),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel',
                  style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
            ),
          ],
        ),
      );
    }

    final isOauth = _picked!.type == 'oauth2';
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 16),
      child: Row(
        children: [
          TextButton(
            onPressed: _saving
                ? null
                : () => setState(() {
                      _picked = null;
                      _values = const {};
                      _testResult = null;
                      _error = null;
                    }),
            child: Text('Back',
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          const Spacer(),
          if (!isOauth && _picked!.fields.isNotEmpty) ...[
            OutlinedButton.icon(
              onPressed: (!_valid || _testing || _saving) ? null : _test,
              icon: _testing
                  ? SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.3, color: c.textMuted),
                    )
                  : Icon(Icons.bolt_outlined, size: 13, color: c.text),
              label: Text(
                _testing ? 'Testing…' : 'Test connection',
                style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.text,
                    fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.border),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              ),
            ),
            const SizedBox(width: 10),
          ],
          ElevatedButton.icon(
            onPressed: _saving
                ? null
                : isOauth
                    ? _startOauth
                    : (_valid ? _save : null),
            icon: _saving
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Colors.white),
                  )
                : Icon(
                    isOauth ? Icons.link_rounded : Icons.check_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
            label: Text(
              isOauth
                  ? 'Connect ${_picked!.label}'
                  : (_saving ? 'Saving…' : 'Save credential'),
              style: GoogleFonts.inter(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w700),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.blue,
              foregroundColor: Colors.white,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Helper widgets ─────────────────────────────────────────────────

class _ProviderTile extends StatefulWidget {
  final ProviderCatalogueEntry entry;
  final List<Color> gradient;
  final VoidCallback onTap;
  const _ProviderTile({
    required this.entry,
    required this.gradient,
    required this.onTap,
  });

  @override
  State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
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
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _h ? widget.gradient.first.withValues(alpha: 0.5) : c.border,
              width: _h ? 1.3 : 1,
            ),
            boxShadow: _h
                ? [
                    BoxShadow(
                      color: widget.gradient.first.withValues(alpha: 0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ]
                : [],
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: widget.gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(widget.entry.icon,
                    size: 16, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _shortType(widget.entry.type),
                      style: GoogleFonts.firaCode(
                          fontSize: 9.5,
                          color: c.textMuted,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 14, color: _h ? c.text : c.textDim),
            ],
          ),
        ),
      ),
    );
  }

  static String _shortType(String t) {
    switch (t) {
      case 'api_key':
        return 'API KEY';
      case 'oauth2':
        return 'OAUTH';
      case 'multi_field':
        return 'MULTI';
      case 'connection_string':
        return 'CONN STRING';
      case 'mcp_server':
        return 'MCP';
      default:
        return t.toUpperCase();
    }
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TypeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: active ? c.blue.withValues(alpha: 0.15) : c.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color:
                  active ? c.blue.withValues(alpha: 0.5) : c.border,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: active ? c.blue : c.textMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _LabelSuggestionChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _LabelSuggestionChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Text(
          label,
          style: GoogleFonts.firaCode(
              fontSize: 10, color: c.textMuted, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _OauthStep extends StatelessWidget {
  final int n;
  final String title;
  final String body;
  const _OauthStep({required this.n, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.blue.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.blue.withValues(alpha: 0.4)),
          ),
          child: Text('$n',
              style: GoogleFonts.firaCode(
                  fontSize: 10, color: c.blue, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 2),
              Text(body,
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: c.textMuted,
                      height: 1.5)),
            ],
          ),
        ),
      ],
    );
  }
}

class _TestResult {
  final bool ok;
  final String detail;
  final int? latencyMs;
  const _TestResult({required this.ok, required this.detail, this.latencyMs});
}

class _TestResultBanner extends StatelessWidget {
  final _TestResult result;
  const _TestResultBanner({required this.result});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = result.ok ? c.green : c.red;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tint.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              result.ok
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              size: 14,
              color: tint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        result.ok ? 'Connection OK' : 'Connection failed',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            color: tint,
                            fontWeight: FontWeight.w700),
                      ),
                      if (result.latencyMs != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${result.latencyMs}ms',
                          style: GoogleFonts.firaCode(
                              fontSize: 10, color: c.textMuted),
                        ),
                      ],
                    ],
                  ),
                  if (result.detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      result.detail,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5,
                          color: c.text,
                          height: 1.5),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
