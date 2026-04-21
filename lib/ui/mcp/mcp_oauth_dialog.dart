/// MCP OAuth install flow — client-orchestrated in 8 steps.
///
/// 1. User clicks Install on a catalog entry with `oauth_provider`
/// 2. Client fetches the catalog detail (already done by caller)
/// 3. Client calls `POST /api/mcp/oauth/start` → `{auth_url, state}`
/// 4. Client opens `auth_url` in the system browser
/// 5. Client polls `GET /api/mcp/oauth/status?state=X` every 2s
/// 6. User authorises on the provider's site
/// 7. Daemon handles the callback, exchanges the code, creates the
///    MCP server row + credential
/// 8. Poll returns `completed` → client finishes the install, shows
///    success, closes the dialog
///
/// Errors, cancels and timeouts all surface inline in the dialog —
/// we never just silently abort a half-started flow.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/mcp_server.dart';
import '../../services/mcp_service.dart';
import '../../theme/app_theme.dart';

enum _OauthPhase {
  /// Before any request — we show the step list + Connect button.
  idle,

  /// `POST /api/mcp/oauth/start` in flight.
  starting,

  /// Waiting on the user to finish the provider flow in their
  /// browser. Poll loop is running.
  waitingForAuth,

  /// `status == completed` — brief success screen, dialog closes.
  completed,

  /// `status == failed` or network error → error message + retry.
  failed,

  /// Timed out without a status change.
  timedOut,
}

/// Public entry point. Returns true on success so the caller knows
/// to refresh its server list.
Future<bool> showMcpOauthDialog(
  BuildContext context, {
  required McpCatalogueEntry entry,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _McpOauthDialog(entry: entry),
  );
  return result == true;
}

class _McpOauthDialog extends StatefulWidget {
  final McpCatalogueEntry entry;
  const _McpOauthDialog({required this.entry});

  @override
  State<_McpOauthDialog> createState() => _McpOauthDialogState();
}

class _McpOauthDialogState extends State<_McpOauthDialog> {
  final _svc = McpService();

  _OauthPhase _phase = _OauthPhase.idle;
  String? _authUrl;
  String? _state;
  String? _error;
  Timer? _pollTimer;
  DateTime? _pollStartedAt;
  static const _pollInterval = Duration(seconds: 2);
  static const _pollTimeout = Duration(minutes: 5);

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // ── Step 3: start the flow ──────────────────────────────────────
  Future<void> _startFlow() async {
    setState(() {
      _phase = _OauthPhase.starting;
      _error = null;
    });
    try {
      final resp = await _svc.startOAuth(widget.entry.name);
      final url = resp?['auth_url'] as String?;
      final state = resp?['state'] as String?;
      if (url == null || url.isEmpty || state == null) {
        setState(() {
          _phase = _OauthPhase.failed;
          _error = 'Daemon did not return a valid auth URL.';
        });
        return;
      }
      _authUrl = url;
      _state = state;

      // Step 4: open the browser. If launchUrl fails (headless
      // sandbox, missing browser), copy the URL to the clipboard
      // so the user can paste it manually — flow still works.
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        await Clipboard.setData(ClipboardData(text: url));
      }
      if (!mounted) return;

      // Step 5: start polling.
      setState(() => _phase = _OauthPhase.waitingForAuth);
      _pollStartedAt = DateTime.now();
      _schedulePoll();
    } on McpException catch (e) {
      setState(() {
        _phase = _OauthPhase.failed;
        _error = e.message;
      });
    }
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(_pollInterval, _doPoll);
  }

  // ── Step 6–8: poll for completion ───────────────────────────────
  Future<void> _doPoll() async {
    if (!mounted || _state == null) return;
    final elapsed = DateTime.now().difference(_pollStartedAt!);
    if (elapsed > _pollTimeout) {
      setState(() => _phase = _OauthPhase.timedOut);
      return;
    }
    final resp = await _svc.pollOAuthStatus(_state!);
    if (!mounted) return;
    final status = resp?['status'] as String? ?? 'pending';
    if (status == 'completed') {
      setState(() => _phase = _OauthPhase.completed);
      // Let the user see the success state for ~1.2s then close.
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) Navigator.of(context).pop(true);
      });
      return;
    }
    if (status == 'failed') {
      setState(() {
        _phase = _OauthPhase.failed;
        _error = (resp?['error'] as String?) ?? 'Provider rejected the request.';
      });
      return;
    }
    // Still pending → schedule next tick.
    _schedulePoll();
  }

  void _cancel() {
    _pollTimer?.cancel();
    Navigator.of(context).pop(false);
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(c),
              const SizedBox(height: 18),
              _buildBody(c),
              const SizedBox(height: 20),
              _buildFooter(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.blue.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.blue.withValues(alpha: 0.4)),
          ),
          child: Icon(Icons.link_rounded, size: 20, color: c.blue),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Connect ${widget.entry.label}',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: c.textBright,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'OAuth · ${widget.entry.oauthProvider ?? "provider"}',
                style: GoogleFonts.firaCode(
                  fontSize: 10.5,
                  color: c.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          iconSize: 16,
          icon: Icon(Icons.close_rounded, color: c.textMuted),
          onPressed:
              _phase == _OauthPhase.starting ? null : _cancel,
        ),
      ],
    );
  }

  Widget _buildBody(AppColors c) {
    switch (_phase) {
      case _OauthPhase.idle:
        return _buildStepList(c);
      case _OauthPhase.starting:
        return _buildStarting(c);
      case _OauthPhase.waitingForAuth:
        return _buildWaiting(c);
      case _OauthPhase.completed:
        return _buildCompleted(c);
      case _OauthPhase.failed:
        return _buildFailed(c);
      case _OauthPhase.timedOut:
        return _buildTimedOut(c);
    }
  }

  Widget _buildStepList(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepRow(
          n: 1,
          title: 'Click Connect',
          body:
              'We request an auth URL from the daemon and open it in your browser.',
          current: false,
        ),
        const SizedBox(height: 10),
        _StepRow(
          n: 2,
          title: 'Authorise on ${widget.entry.oauthProvider ?? "the provider"}',
          body:
              'Sign in and approve the requested scopes. Digitorn never sees your password.',
          current: false,
        ),
        const SizedBox(height: 10),
        _StepRow(
          n: 3,
          title: 'Come back here',
          body:
              'We poll the daemon for completion — no need to paste anything.',
          current: false,
        ),
      ],
    );
  }

  Widget _buildStarting(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: c.blue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Requesting auth URL from the daemon…',
              style: GoogleFonts.inter(
                  fontSize: 12.5, color: c.text, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaiting(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.blue.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.blue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Waiting for you to finish on ${widget.entry.oauthProvider ?? "the provider"}…',
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w600,
                      height: 1.45),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            "Your browser should have opened. If it didn't, the URL has "
            "been copied to your clipboard — paste it into a browser tab.",
            style: GoogleFonts.inter(
                fontSize: 11.5, color: c.text, height: 1.5),
          ),
          if (_authUrl != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: SelectableText(
                _authUrl!,
                maxLines: 2,
                style: GoogleFonts.firaCode(
                    fontSize: 10.5, color: c.textMuted, height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompleted(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.green.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.green.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 18, color: c.green),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Connected! Credential stored and MCP server installed.',
              style: GoogleFonts.inter(
                  fontSize: 12.5,
                  color: c.green,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailed(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.red.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: c.red),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Connection failed',
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.red)),
                const SizedBox(height: 4),
                Text(
                  _error ?? 'The provider rejected the request.',
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: c.text,
                      height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimedOut(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.orange.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, size: 16, color: c.orange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Timed out waiting for the provider. Click Retry to "
              "restart the flow.",
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.text, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(AppColors c) {
    final canRestart = _phase == _OauthPhase.failed ||
        _phase == _OauthPhase.timedOut;
    final showConnect = _phase == _OauthPhase.idle || canRestart;
    final disabled = _phase == _OauthPhase.starting ||
        _phase == _OauthPhase.waitingForAuth ||
        _phase == _OauthPhase.completed;
    return Row(
      children: [
        TextButton(
          onPressed: disabled ? null : _cancel,
          child: Text('Cancel',
              style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ),
        const Spacer(),
        if (showConnect)
          ElevatedButton.icon(
            onPressed: _startFlow,
            icon: Icon(
              canRestart ? Icons.refresh_rounded : Icons.link_rounded,
              size: 14,
              color: Colors.white,
            ),
            label: Text(
              canRestart ? 'Retry' : 'Connect',
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
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            ),
          ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final int n;
  final String title;
  final String body;
  final bool current;
  const _StepRow({
    required this.n,
    required this.title,
    required this.body,
    required this.current,
  });

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
            color: (current ? c.blue : c.textMuted).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: (current ? c.blue : c.textMuted)
                  .withValues(alpha: 0.35),
            ),
          ),
          child: Text(
            '$n',
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: current ? c.blue : c.textMuted,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
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
