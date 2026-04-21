/// First-use credential picker — shown when the daemon emits a
/// `credential_auth_required` SSE event. Lets the user either pick
/// an existing matching credential or create a new one inline,
/// then posts the grant. The chat panel awaits this dialog and
/// re-sends the buffered message on success.
///
/// Three layouts depending on the provider type:
///  1. `api_key` / `multi_field` / `connection_string` — list of
///     candidates + "Add new" radio that expands an inline form.
///  2. `oauth2` — Connect button that launches the browser flow,
///     polls until the grant is created, returns success.
///  3. `oauth2` with `oauth_missing_scopes` — re-connect with extra
///     scopes (same flow, different copy).
///
/// Returns `true` on success (the chat should retry), `false`/null
/// on cancel or failure.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/credential_v2.dart';
import '../../services/credential_service.dart';
import '../../services/credentials_v2_service.dart';
import '../../theme/app_theme.dart';
import 'credential_field_form.dart';

class CredentialPickerDialog {
  /// Show the picker. Uses a centered modal on desktop / web /
  /// tablets and a bottom sheet on phones (per the brief).
  /// Returns `true` when the user successfully authorised — the
  /// caller should re-send its buffered message.
  static Future<bool> show(
    BuildContext context, {
    required CredentialAuthRequiredEvent event,
  }) async {
    final isMobile = MediaQuery.of(context).size.width < 600;
    bool? result;
    if (isMobile) {
      result = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: Colors.transparent,
        builder: (_) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom),
          child: _PickerScaffold(event: event, isBottomSheet: true),
        ),
      );
    } else {
      result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PickerScaffold(event: event),
      );
    }
    return result == true;
  }
}

class _PickerScaffold extends StatefulWidget {
  final CredentialAuthRequiredEvent event;
  final bool isBottomSheet;
  const _PickerScaffold({
    required this.event,
    this.isBottomSheet = false,
  });

  @override
  State<_PickerScaffold> createState() => _PickerScaffoldState();
}

class _PickerScaffoldState extends State<_PickerScaffold> {
  /// Picked existing credential id, "_new" when the user wants to
  /// create one inline, null when nothing is selected yet.
  String? _selectedId;

  bool _busy = false;
  String? _error;
  String? _progress;

  // Inline form state (only used when _selectedId == "_new")
  Map<String, String> _newFields = const {};
  bool _newFieldsValid = false;
  final _labelCtrl = TextEditingController(text: 'default');

  /// Live candidate list. Seeded from the event, but refreshed from
  /// the server if the daemon sent an empty list — otherwise the
  /// picker forces "_new" and creates a duplicate credential on
  /// every retry, causing the "form keeps reappearing" loop.
  List<CredentialV2> _candidates = const [];
  bool _fetchingCandidates = false;

  @override
  void initState() {
    super.initState();
    _candidates = List.of(widget.event.candidates);
    if (_candidates.length == 1) {
      _selectedId = _candidates.first.id;
    } else if (_candidates.isEmpty) {
      _selectedId = '_new';
      WidgetsBinding.instance.addPostFrameCallback((_) => _fetchCandidates());
    }
  }

  Future<void> _fetchCandidates() async {
    if (_fetchingCandidates) return;
    final provider = widget.event.provider.trim();
    if (provider.isEmpty) return;
    setState(() => _fetchingCandidates = true);
    try {
      debugPrint('[picker] fetching candidates for provider=$provider');
      final list = await CredentialsV2Service().list(provider: provider);
      debugPrint('[picker] fetched ${list.length} candidates for $provider');
      if (!mounted) return;
      setState(() {
        _candidates = list;
        _fetchingCandidates = false;
        if (list.length == 1) {
          _selectedId = list.first.id;
        } else if (list.isNotEmpty && _selectedId == '_new') {
          _selectedId = list.first.id;
        }
      });
    } catch (e) {
      debugPrint('[picker] candidate fetch failed: $e');
      if (mounted) setState(() => _fetchingCandidates = false);
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  bool get _isOauth => widget.event.isOauth;

  Future<void> _authorize() async {
    debugPrint('[picker] authorize clicked — selectedId=$_selectedId '
        'provider="${widget.event.provider}" '
        'providerType="${widget.event.providerType}" '
        'fields=${_newFields.keys.toList()} '
        'valid=$_newFieldsValid '
        'candidates=${_candidates.length}');
    if (_isOauth) {
      await _runOauth();
      return;
    }
    if (_selectedId == null) {
      setState(() => _error = 'Pick a credential or create a new one');
      return;
    }
    // Sanity: a malformed event with an empty provider id would
    // create an orphan credential the daemon can never look up,
    // causing the "click Authorize → loops back" bug. Refuse up
    // front so the user sees why.
    if (widget.event.provider.trim().isEmpty) {
      debugPrint('[picker] REFUSED: provider id is empty');
      setState(() => _error =
          'Event is missing a provider id — cannot create a credential. '
          'Check the daemon payload.');
      return;
    }
    // Same defense for app_id: an empty one means the grant will be
    // stored orphaned and the turn will re-emit credential_required
    // forever. The chat panel tries to backfill it from the active
    // session, so if we're still here with an empty app_id the user
    // is in a broken state.
    if (widget.event.appId.trim().isEmpty) {
      debugPrint('[picker] REFUSED: app id is empty');
      setState(() => _error =
          'Event is missing an app id — the grant would be orphaned. '
          'Reload the chat and try again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String credentialId;
      if (_selectedId == '_new') {
        if (!_newFieldsValid || _newFields.isEmpty) {
          debugPrint(
              '[picker] REFUSED: form not valid (valid=$_newFieldsValid, '
              'fields=${_newFields.keys.toList()})');
          throw const CredV2Exception('Fill the required fields first');
        }
        debugPrint('[picker] → create provider=${widget.event.provider} '
            'type=${widget.event.providerType} '
            'field_count=${_newFields.length}');
        final created = await CredentialsV2Service().create(
          providerName: widget.event.provider,
          providerType: widget.event.providerType,
          label: _labelCtrl.text.trim().isEmpty
              ? 'default'
              : _labelCtrl.text.trim(),
          fields: _newFields,
        );
        credentialId = created.id;
        debugPrint('[picker] ← created id=$credentialId');
      } else {
        credentialId = _selectedId!;
      }

      debugPrint('[picker] → grant cred=$credentialId app=${widget.event.appId}');
      await CredentialsV2Service().grant(
        credentialId: credentialId,
        appId: widget.event.appId,
      );
      debugPrint('[picker] ← grant OK, popping true');
      if (mounted) Navigator.pop(context, true);
    } on CredV2Exception catch (e) {
      debugPrint('[picker] CredV2Exception: ${e.message} '
          '(status=${e.statusCode})');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e, st) {
      // Defensive: never silently swallow a non-CredV2Exception
      // (e.g. a TypeError from parsing). Before this catch the
      // picker could pop(true) on a partial failure and trigger
      // the infinite re-prompt loop.
      debugPrint('[picker] UNEXPECTED: $e\n$st');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Unexpected error: $e';
        });
      }
    }
  }

  Future<void> _runOauth() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Opening browser…';
    });
    try {
      // Try the unified v2 route first. It returns `{auth_url,
      // state}` same shape as the legacy route; we fall back to the
      // old per-app OAuth flow on 404/405 so the picker still works
      // against older daemons.
      String authUrl;
      String stateToken;
      try {
        final start = await CredentialsV2Service().startUserOauth(
          providerName: widget.event.provider,
          label: _labelCtrl.text.trim().isEmpty
              ? 'default'
              : _labelCtrl.text.trim(),
        );
        if (start == null) {
          throw const CredV2Exception('Empty OAuth start response');
        }
        authUrl = start['auth_url']?.toString() ?? '';
        stateToken = start['state']?.toString() ?? '';
        if (authUrl.isEmpty || stateToken.isEmpty) {
          throw const CredV2Exception('OAuth start missing auth_url/state');
        }
      } on CredV2Exception {
        // Legacy per-app fallback.
        final legacy = await CredentialService().startOauth(
          appId: widget.event.appId,
          providerName: widget.event.provider,
        );
        authUrl = legacy.authUrl;
        stateToken = legacy.state;
      }

      await launchUrl(Uri.parse(authUrl),
          mode: LaunchMode.externalApplication);
      if (!mounted) return;
      setState(() => _progress = 'Waiting for consent in your browser…');

      // Poll loop — same cadence as the legacy helper. Bail out
      // after ~3 min to avoid a stuck dialog.
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      String? finalStatus;
      String? finalError;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        Map<String, dynamic> status;
        try {
          status = await CredentialsV2Service().pollOauthStatus(
            providerName: widget.event.provider,
            state: stateToken,
          );
        } on CredV2Exception {
          // Fall back to legacy polling once if the v2 route isn't
          // there.
          final legacy = await CredentialService().getOauthStatus(
            appId: widget.event.appId,
            providerName: widget.event.provider,
            state: stateToken,
          );
          status = {
            'status': legacy.status,
            'error': legacy.error,
          };
        }
        final s = status['status']?.toString() ?? 'pending';
        if (s == 'connected') {
          finalStatus = s;
          break;
        }
        if (s == 'failed' || s == 'cancelled' || s == 'error') {
          finalStatus = s;
          finalError = status['error']?.toString();
          break;
        }
      }

      if (!mounted) return;
      if (finalStatus == 'connected') {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _busy = false;
          _progress = null;
          _error = finalError ?? 'Connection ${finalStatus ?? "timed out"}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ev = widget.event;
    final providerLabel = ev.providerLabel.isNotEmpty
        ? ev.providerLabel
        : _humanise(ev.provider);
    final isReconnect = _isOauth && ev.oauthMissingScopes.isNotEmpty;
    final isReauth = ev.isReauth;

    final screenW = MediaQuery.sizeOf(context).width;
    final dialogMaxW = screenW < 560 ? screenW - 32 : 520.0;
    final body = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: dialogMaxW),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
              // ── Header ─────────────────────────────────────────
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: c.blue.withValues(alpha: 0.35)),
                    ),
                    child: Icon(_iconFor(ev.provider),
                        size: 20, color: c.blue),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isReconnect
                              ? '$providerLabel — extra access needed'
                              : isReauth
                                  ? '$providerLabel credential expired'
                                  : ev.agentId != null
                                      ? '${_humanise(ev.agentId!)} asks for a '
                                          '$providerLabel key'
                                      : '$providerLabel access required',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: c.textBright,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          ev.field != null && ev.field!.isNotEmpty
                              ? '${ev.appId} · ${ev.field}'
                              : '${ev.appId} needs to use this provider',
                          style: GoogleFonts.firaCode(
                              fontSize: 10.5, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Daemon-supplied error message (e.g. "Missing credential:
              // 'DEEPSEEK_API_KEY'…"). Shown as an informational pill,
              // not as a failure — the picker is the recovery path.
              if (ev.errorMessage != null && ev.errorMessage!.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.orange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: c.orange.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 14, color: c.orange),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          ev.errorMessage!,
                          style: GoogleFonts.firaCode(
                              fontSize: 11,
                              color: c.text,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              if (_isOauth)
                _buildOauthBody(c, isReconnect)
              else
                _buildKeyBody(c),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.red.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 14, color: c.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: GoogleFonts.firaCode(
                                fontSize: 11, color: c.red, height: 1.4)),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context, false),
                    child: Text('Cancel',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _authorize,
                    icon: _busy
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5, color: Colors.white),
                          )
                        : Icon(
                            _isOauth
                                ? Icons.link_rounded
                                : Icons.check_rounded,
                            size: 14,
                            color: Colors.white),
                    label: Text(
                      _busy
                          ? (_progress ?? 'Working…')
                          : _isOauth
                              ? (isReconnect ? 'Reconnect' : 'Connect')
                              : 'Authorize',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.blue,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

    // Mobile bottom-sheet chrome — rounded top corners, full width,
    // safe-area aware. Desktop / web get the centered Dialog.
    if (widget.isBottomSheet) {
      return SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border.all(color: c.border),
          ),
          child: SingleChildScrollView(child: body),
        ),
      );
    }

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      child: body,
    );
  }

  Widget _buildKeyBody(AppColors c) {
    // Brief explicitly requires the picker to order candidates by
    // `updated_at desc`. We stable-sort here so the freshest one
    // always lands on top, regardless of how the daemon serialises
    // them.
    final candidates = [..._candidates]
      ..sort((a, b) {
        final ta = a.updatedAt;
        final tb = b.updatedAt;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return tb.compareTo(ta);
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (candidates.isNotEmpty) ...[
          Text(
            'Use an existing credential',
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: c.textMuted,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          for (final candidate in candidates)
            _CandidateRow(
              candidate: candidate,
              selected: _selectedId == candidate.id,
              onTap: () => setState(() => _selectedId = candidate.id),
            ),
          const SizedBox(height: 14),
          Text(
            'Or create a new one',
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: c.textMuted,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
        ],
        _NewCredentialOption(
          selected: _selectedId == '_new',
          onTap: () => setState(() => _selectedId = '_new'),
        ),
        if (_selectedId == '_new') ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Label',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c.textBright,
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _labelCtrl,
                  style: GoogleFonts.inter(fontSize: 12, color: c.text),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: c.surface,
                    hintText: 'personal, work, …',
                    hintStyle: GoogleFonts.inter(
                        fontSize: 12, color: c.textDim),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                CredentialFieldForm(
                  fields: widget.event.fieldSpec,
                  onChanged: (vals, valid) {
                    _newFields = vals;
                    _newFieldsValid = valid;
                  },
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOauthBody(AppColors c, bool isReconnect) {
    final scopes = widget.event.oauthMissingScopes.isEmpty
        ? null
        : widget.event.oauthMissingScopes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isReconnect
              ? 'Reconnecting will keep your existing permissions and add the new ones below.'
              : 'You\'ll be redirected to ${_humanise(widget.event.provider)} to authorise the app.',
          style: GoogleFonts.inter(
              fontSize: 12, color: c.text, height: 1.5),
        ),
        if (scopes != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'New scopes requested',
                  style: GoogleFonts.firaCode(
                    fontSize: 9.5,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 6),
                for (final s in scopes)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Icon(Icons.add_circle_outline_rounded,
                            size: 11, color: c.blue),
                        const SizedBox(width: 6),
                        Text(s,
                            style: GoogleFonts.firaCode(
                                fontSize: 11, color: c.text)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  IconData _iconFor(String provider) {
    switch (provider.toLowerCase()) {
      case 'openai':
        return Icons.bolt_rounded;
      case 'anthropic':
        return Icons.auto_awesome_rounded;
      case 'notion':
        return Icons.description_outlined;
      case 'gmail':
      case 'google':
        return Icons.mail_outline_rounded;
      case 'slack':
        return Icons.tag_rounded;
      case 'telegram':
        return Icons.send_rounded;
      case 'discord':
        return Icons.chat_bubble_outline_rounded;
      case 'github':
        return Icons.hub_outlined;
      case 'aws':
        return Icons.cloud_outlined;
      case 'serpapi':
        return Icons.search_rounded;
      case 'deepseek':
        return Icons.psychology_outlined;
      default:
        return Icons.key_rounded;
    }
  }
}

String _humanise(String snake) {
  if (snake.isEmpty) return '';
  return snake
      .split(RegExp(r'[_\-]'))
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

class _CandidateRow extends StatelessWidget {
  final CredentialV2 candidate;
  final bool selected;
  final VoidCallback onTap;
  const _CandidateRow({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final masked = candidate.firstMaskedPreview ?? candidate.label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? c.blue.withValues(alpha: 0.08)
                : c.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? c.blue : c.border, width: selected ? 1.4 : 1),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: selected ? c.blue : c.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      candidate.label,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      masked,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              if (candidate.isSystem)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.purple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                        color: c.purple.withValues(alpha: 0.35)),
                  ),
                  child: Text('SYSTEM',
                      style: GoogleFonts.firaCode(
                          fontSize: 8,
                          color: c.purple,
                          fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewCredentialOption extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  const _NewCredentialOption({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? c.blue.withValues(alpha: 0.08) : c.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? c.blue : c.border, width: selected ? 1.4 : 1),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: selected ? c.blue : c.textMuted,
            ),
            const SizedBox(width: 10),
            Icon(Icons.add_circle_outline_rounded,
                size: 14, color: c.blue),
            const SizedBox(width: 8),
            Text('Add a new credential',
                style: GoogleFonts.inter(
                    fontSize: 12.5,
                    color: c.textBright,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
