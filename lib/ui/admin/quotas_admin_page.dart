/// Admin-only quotas management. Wraps the daemon's
/// `/api/admin/quotas` CRUD — lists every quota row, lets the
/// admin create new ones with the full spec (scope_type + scope_id
/// + app_id + period + tokens_limit) and delete existing ones.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/apps_service.dart';
import '../../services/auth_service.dart';
import '../../services/quotas_service.dart';
import '../../theme/app_theme.dart';
import '../common/themed_dialogs.dart';

class QuotasAdminPage extends StatefulWidget {
  const QuotasAdminPage({super.key});

  @override
  State<QuotasAdminPage> createState() => _QuotasAdminPageState();
}

class _QuotasAdminPageState extends State<QuotasAdminPage> {
  final _svc = QuotasService();
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    _svc.listAll();
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  List<UserQuota> get _filtered {
    if (_query.isEmpty) return _svc.all;
    final q = _query.toLowerCase();
    return _svc.all.where((r) {
      return r.scopeId.toLowerCase().contains(q) ||
          r.subjectLabel.toLowerCase().contains(q) ||
          (r.appId?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Text('Quotas (admin)',
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _svc.loading ? null : () => _svc.listAll(),
          ),
          IconButton(
            icon: Icon(Icons.add_rounded, size: 20, color: c.blue),
            tooltip: 'New quota',
            onPressed: isAdmin ? _createQuota : null,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !isAdmin
          ? _buildForbidden(c)
          : _svc.loading && _svc.all.isEmpty
              ? Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: c.textMuted),
                  ),
                )
              : _svc.error != null
                  ? _buildError(c)
                  : _buildBody(c),
    );
  }

  Widget _buildForbidden(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_outlined, size: 48, color: c.orange),
              const SizedBox(height: 14),
              Text('Admin only',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(
                'You need admin permissions to manage quotas.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
      );

  Widget _buildError(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text(_svc.error ?? 'Unknown error',
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.textMuted)),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: () => _svc.listAll(),
                child: Text('Retry',
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      );

  Widget _buildBody(AppColors c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Quotas',
                  style: GoogleFonts.inter(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  )),
              const SizedBox(height: 5),
              Text(
                '${_svc.all.length} row${_svc.all.length == 1 ? '' : 's'}. '
                'Use scope_type: user (cross-app), user_app (per user per app), '
                'or app (team).',
                style: GoogleFonts.inter(
                    fontSize: 13.5, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 22),
              Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded,
                        size: 15, color: c.textMuted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (v) => setState(() => _query = v.trim()),
                        style: GoogleFonts.inter(
                            fontSize: 12.5, color: c.textBright),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText:
                              'Filter by user id, email or app id…',
                          hintStyle: GoogleFonts.inter(
                              fontSize: 12, color: c.textMuted),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.border),
                ),
                child: Column(
                  children: [
                    _QuotaTableHeader(),
                    for (var i = 0; i < _filtered.length; i++) ...[
                      _QuotaRow(
                        quota: _filtered[i],
                        onDelete: () => _confirmDelete(_filtered[i]),
                      ),
                      if (i < _filtered.length - 1)
                        Divider(height: 1, color: c.border),
                    ],
                    if (_filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(30),
                        child: Text(
                          _query.isNotEmpty
                              ? 'No quota matches "$_query"'
                              : 'No quota defined yet. Click + to create one.',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.textMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _createQuota() async {
    final result = await showDialog<_QuotaFormResult>(
      context: context,
      builder: (_) => const _QuotaCreateDialog(),
    );
    if (result == null) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final q = await _svc.create(
      scopeType: result.scopeType,
      scopeId: result.scopeId,
      period: result.period,
      tokensLimit: result.tokensLimit,
      appId: result.appId,
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          q != null ? 'Quota created' : 'Create failed (admin only?)',
          style: GoogleFonts.inter(fontSize: 12),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _confirmDelete(UserQuota q) async {
    final ok = await showThemedConfirmDialog(
      context,
      title: 'Delete quota?',
      body:
          'The ${q.scopeType} quota for ${q.subjectLabel} will be removed and '
          'the subject will revert to the workspace default.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok != true) return;
    await _svc.delete(q.id);
  }
}

// ─── Table header ────────────────────────────────────────────────────

class _QuotaTableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    TextStyle h() => GoogleFonts.firaCode(
          fontSize: 10,
          color: c.textMuted,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Row(
        children: [
          SizedBox(width: 92, child: Text('SCOPE', style: h())),
          Expanded(flex: 3, child: Text('SUBJECT', style: h())),
          Expanded(flex: 2, child: Text('APP', style: h())),
          SizedBox(width: 74, child: Text('PERIOD', style: h())),
          SizedBox(width: 110, child: Text('LIMIT', style: h())),
          Expanded(flex: 3, child: Text('USAGE', style: h())),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _QuotaRow extends StatelessWidget {
  final UserQuota quota;
  final VoidCallback onDelete;
  const _QuotaRow({required this.quota, required this.onDelete});

  Color _scopeTint(AppColors c) {
    switch (quota.scopeType) {
      case 'user':
        return c.blue;
      case 'user_app':
        return c.purple;
      case 'app':
        return c.green;
      default:
        return c.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final frac = quota.fraction;
    final tint = frac > 0.9
        ? c.red
        : frac > 0.7
            ? c.orange
            : c.green;
    final scopeTint = _scopeTint(c);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scopeTint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: scopeTint.withValues(alpha: 0.35)),
              ),
              child: Text(
                quota.scopeType.toUpperCase(),
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: scopeTint,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(quota.subjectLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: c.textBright,
                        fontWeight: FontWeight.w600)),
                if (quota.email != null &&
                    quota.email != quota.subjectLabel)
                  Text(quota.email!,
                      style: GoogleFonts.firaCode(
                          fontSize: 9.5, color: c.textMuted)),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              quota.appId ?? '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: quota.appId != null ? c.text : c.textDim),
            ),
          ),
          SizedBox(
            width: 74,
            child: Text(
              quota.period.toUpperCase(),
              style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: c.textMuted,
                  fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              _fmtInt(quota.tokensLimit),
              style:
                  GoogleFonts.firaCode(fontSize: 12, color: c.textBright),
            ),
          ),
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 5,
                      backgroundColor: c.surfaceAlt,
                      valueColor: AlwaysStoppedAnimation(tint),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(frac * 100).toStringAsFixed(0)}%',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.firaCode(
                        fontSize: 10.5, color: tint),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: IconButton(
              tooltip: 'Delete',
              iconSize: 14,
              icon: Icon(Icons.delete_outline_rounded, color: c.red),
              onPressed: onDelete,
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtInt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

class _QuotaFormResult {
  final String scopeType;
  final String scopeId;
  final String? appId;
  final String period;
  final int tokensLimit;
  const _QuotaFormResult({
    required this.scopeType,
    required this.scopeId,
    required this.period,
    required this.tokensLimit,
    this.appId,
  });
}

class _QuotaCreateDialog extends StatefulWidget {
  const _QuotaCreateDialog();

  @override
  State<_QuotaCreateDialog> createState() => _QuotaCreateDialogState();
}

class _QuotaCreateDialogState extends State<_QuotaCreateDialog> {
  String _scopeType = 'user';
  String _period = 'month';
  String? _appId;
  final _scopeIdCtrl = TextEditingController();
  final _tokensCtrl = TextEditingController(text: '1000000');
  String? _error;

  @override
  void dispose() {
    _scopeIdCtrl.dispose();
    _tokensCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final apps = AppsService().apps;
    return themedAlertDialog(
      context,
      title: 'New quota',
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width < 460
            ? MediaQuery.sizeOf(context).width - 48
            : 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Scope type
            Text('Scope type',
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
            const SizedBox(height: 6),
            Row(
              children: [
                _ScopeOption(
                  label: 'User',
                  sub: 'cross-app',
                  value: 'user',
                  selected: _scopeType == 'user',
                  onTap: () => setState(() => _scopeType = 'user'),
                ),
                const SizedBox(width: 8),
                _ScopeOption(
                  label: 'User · App',
                  sub: 'per user, per app',
                  value: 'user_app',
                  selected: _scopeType == 'user_app',
                  onTap: () => setState(() => _scopeType = 'user_app'),
                ),
                const SizedBox(width: 8),
                _ScopeOption(
                  label: 'App',
                  sub: 'shared team',
                  value: 'app',
                  selected: _scopeType == 'app',
                  onTap: () => setState(() => _scopeType = 'app'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Scope id
            Text(
              _scopeType == 'app' ? 'App id' : 'User id',
              style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: c.textMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _scopeIdCtrl,
              style: GoogleFonts.firaCode(fontSize: 12, color: c.textBright),
              decoration: themedInputDecoration(
                context,
                hintText: _scopeType == 'app'
                    ? 'e.g. digitorn-code'
                    : 'e.g. alice',
              ),
            ),
            if (_scopeType == 'user_app') ...[
              const SizedBox(height: 14),
              Text('App',
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _appId,
                items: [
                  const DropdownMenuItem(value: null, child: Text('—')),
                  for (final a in apps)
                    DropdownMenuItem(
                      value: a.appId,
                      child: Text('${a.name} (${a.appId})',
                          style: GoogleFonts.firaCode(fontSize: 11)),
                    ),
                ],
                onChanged: (v) => setState(() => _appId = v),
                decoration: themedInputDecoration(context,
                    hintText: 'Pick an app'),
                dropdownColor: c.surface,
              ),
            ],
            const SizedBox(height: 14),
            // Period
            Text('Period',
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final p in const ['day', 'week', 'month'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(p),
                      selected: _period == p,
                      onSelected: (_) => setState(() => _period = p),
                      selectedColor: c.blue.withValues(alpha: 0.2),
                      labelStyle: GoogleFonts.firaCode(
                        fontSize: 11,
                        color: _period == p ? c.blue : c.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            // Tokens limit
            Text('Tokens limit',
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
            const SizedBox(height: 6),
            TextField(
              controller: _tokensCtrl,
              keyboardType: TextInputType.number,
              style: GoogleFonts.firaCode(fontSize: 12, color: c.textBright),
              decoration: themedInputDecoration(
                context,
                hintText: 'e.g. 1000000',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style:
                      GoogleFonts.firaCode(fontSize: 11, color: c.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style:
                  GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ),
        ElevatedButton(
          onPressed: () {
            final scopeId = _scopeIdCtrl.text.trim();
            final tokens = int.tryParse(_tokensCtrl.text.trim()) ?? 0;
            if (scopeId.isEmpty) {
              setState(() => _error = 'Scope id is required.');
              return;
            }
            if (tokens <= 0) {
              setState(() => _error = 'Tokens limit must be > 0.');
              return;
            }
            if (_scopeType == 'user_app' && (_appId?.isEmpty ?? true)) {
              setState(() => _error = 'Pick an app for user_app scope.');
              return;
            }
            Navigator.pop(
              context,
              _QuotaFormResult(
                scopeType: _scopeType,
                scopeId: scopeId,
                appId: _scopeType == 'user_app' ? _appId : null,
                period: _period,
                tokensLimit: tokens,
              ),
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: c.blue,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          child: Text('Create',
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _ScopeOption extends StatelessWidget {
  final String label;
  final String sub;
  final String value;
  final bool selected;
  final VoidCallback onTap;
  const _ScopeOption({
    required this.label,
    required this.sub,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color:
                selected ? c.blue.withValues(alpha: 0.12) : c.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? c.blue.withValues(alpha: 0.5)
                  : c.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      color: selected ? c.blue : c.textBright,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(sub,
                  style: GoogleFonts.inter(
                      fontSize: 9.5,
                      color: c.textMuted,
                      height: 1.3)),
            ],
          ),
        ),
      ),
    );
  }
}
