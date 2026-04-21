/// Digitorn Widgets v1 — action dispatcher.
///
/// Routes a resolved [ActionSpec] to the right side-effect runner.
/// Every action returns a [ActionResult] so the caller can chain
/// (`on_success` / `on_error`) and sequences can short-circuit.
///
/// The dispatcher is intentionally decoupled from the chat layer:
/// main.dart wires callbacks ([chatSender], [toolRunner], …) so
/// this file has no hard dependency on the chat panel.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'bindings.dart';
import 'data_runtime.dart';
import 'models.dart';
import 'service.dart';
import 'state.dart';

/// Result of executing one action — used for chaining.
class ActionResult {
  final bool ok;
  final dynamic value;
  final String? error;
  const ActionResult({this.ok = true, this.value, this.error});

  factory ActionResult.success([dynamic v]) => ActionResult(ok: true, value: v);
  factory ActionResult.failure(String msg) =>
      ActionResult(ok: false, error: msg);
}

/// Callbacks the host can provide so the dispatcher stays
/// decoupled from the chat / modal / workspace layers.
class ActionHooks {
  /// Sends a message in the current chat as if the user typed it.
  final Future<void> Function(String message, {bool silent, Map<String, dynamic>? context})?
      chatSender;

  /// Runs an agent tool and returns its result. Wired by main.dart
  /// to the chat pipeline.
  final Future<dynamic> Function(String tool, Map<String, dynamic> args)?
      toolRunner;

  /// Opens a modal by name. The host provides this so the dispatcher
  /// can call `open_modal` without knowing modal internals.
  final void Function(String modalName, Map<String, dynamic>? ctx)? openModal;

  /// Pushes a widget into a workspace tab (Z3).
  final void Function({
    String? tabId,
    WidgetNode? tree,
    String? ref,
    Map<String, dynamic>? ctx,
    String? title,
    String? icon,
  })? openWorkspace;

  /// Closes the host container (modal / bubble).
  final VoidCallback? closeHost;

  /// Navigates to another app or workspace tab.
  final void Function({String? appId, String? workspaceTab})? navigate;

  const ActionHooks({
    this.chatSender,
    this.toolRunner,
    this.openModal,
    this.openWorkspace,
    this.closeHost,
    this.navigate,
  });
}

class ActionDispatcher {
  final String appId;
  final WidgetRuntimeState state;
  final DataRuntime data;
  final ActionHooks hooks;

  ActionDispatcher({
    required this.appId,
    required this.state,
    required this.data,
    required this.hooks,
  });

  /// Run an action. When [scopeExtra] is non-null, its keys are
  /// layered on top of the runtime scope — used to pass `row`,
  /// `item`, `error` in callback contexts.
  Future<ActionResult> run(
    ActionSpec action, {
    required BuildContext context,
    Map<String, dynamic>? scopeExtra,
  }) async {
    try {
      final result = await _runInner(action, context, scopeExtra);
      if (result.ok) {
        final onSuccess = action.sub('on_success');
        if (onSuccess != null && context.mounted) {
          await run(onSuccess, context: context, scopeExtra: scopeExtra);
        }
      } else {
        final onError = action.sub('on_error');
        if (onError != null && context.mounted) {
          final extra = {
            ...?scopeExtra,
            'error': {'message': result.error ?? 'error'},
          };
          await run(onError, context: context, scopeExtra: extra);
        }
      }
      return result;
    } catch (e) {
      return ActionResult.failure(e.toString());
    }
  }

  Future<ActionResult> _runInner(
    ActionSpec action,
    BuildContext context,
    Map<String, dynamic>? scopeExtra,
  ) async {
    final scope = state.buildScope(extra: scopeExtra);
    switch (action.type) {
      case 'chat':
        return _doChat(action, scope);
      case 'tool':
        return _doTool(action, scope);
      case 'http':
        return _doHttp(action, scope);
      case 'open_url':
        return _doOpenUrl(action, scope);
      case 'open_modal':
        return _doOpenModal(action, scope);
      case 'open_workspace':
        return _doOpenWorkspace(action, scope);
      case 'close':
        hooks.closeHost?.call();
        return ActionResult.success();
      case 'set_state':
        return _doSetState(action, scope);
      case 'refresh':
        return _doRefresh(action, scope);
      case 'copy':
        return _doCopy(action, scope, context);
      case 'download':
        return _doDownload(action, scope);
      case 'navigate':
        return _doNavigate(action, scope);
      case 'confirm':
        return _doConfirm(action, context, scopeExtra);
      case 'sequence':
        return _doSequence(action, context, scopeExtra);
      case 'noop':
        return ActionResult.success();
      default:
        return ActionResult.failure('Unknown action: ${action.type}');
    }
  }

  // ── action impls ────────────────────────────────────────────

  Future<ActionResult> _doChat(ActionSpec a, BindingScope scope) async {
    final tpl = a.props['template'] as String? ?? a.props['message'] as String? ?? '';
    final message = evalTemplate(tpl, scope);
    final silent = a.props['silent'] == true;
    final ctx = _resolveMap(a.props['context'], scope);
    final sender = hooks.chatSender;
    if (sender == null) return ActionResult.failure('No chat sender wired');
    await sender(message, silent: silent, context: ctx);
    return ActionResult.success();
  }

  Future<ActionResult> _doTool(ActionSpec a, BindingScope scope) async {
    final tool = evalTemplate(a.props['tool'] as String? ?? '', scope);
    final args = _resolveMap(a.props['args'], scope) ?? const {};
    final runner = hooks.toolRunner;
    if (runner == null) return ActionResult.failure('No tool runner wired');
    try {
      final value = await runner(tool, args);
      return ActionResult.success(value);
    } catch (e) {
      return ActionResult.failure(e.toString());
    }
  }

  Future<ActionResult> _doHttp(ActionSpec a, BindingScope scope) async {
    final method = (a.props['method'] as String? ?? 'GET').toUpperCase();
    final url = evalTemplate(a.props['url'] as String? ?? '', scope);
    final body = _resolveMap(a.props['body'], scope);
    final query = _resolveMap(a.props['query'], scope);
    try {
      final result = await WidgetsService().fetchBinding(
        appId,
        method: method,
        url: url,
        body: body,
        query: query,
      );
      final thenRefresh = a.props['then_refresh'];
      if (thenRefresh is List) {
        for (final name in thenRefresh) {
          await data.refresh(name.toString());
        }
      } else if (thenRefresh is String) {
        await data.refresh(thenRefresh);
      }
      return ActionResult.success(result);
    } catch (e) {
      return ActionResult.failure(e.toString());
    }
  }

  Future<ActionResult> _doOpenUrl(ActionSpec a, BindingScope scope) async {
    final url = evalTemplate(a.props['url'] as String? ?? '', scope);
    final uri = Uri.tryParse(url);
    if (uri == null) return ActionResult.failure('Invalid URL');
    final external = a.props['external'] != false;
    final ok = await launchUrl(
      uri,
      mode: external
          ? LaunchMode.externalApplication
          : LaunchMode.inAppWebView,
    );
    return ok ? ActionResult.success() : ActionResult.failure('Launch failed');
  }

  Future<ActionResult> _doOpenModal(ActionSpec a, BindingScope scope) async {
    final name = a.props['modal'] as String? ?? '';
    final ctx = _resolveMap(a.props['ctx'], scope);
    final opener = hooks.openModal;
    if (opener == null) return ActionResult.failure('No modal host wired');
    opener(name, ctx);
    return ActionResult.success();
  }

  Future<ActionResult> _doOpenWorkspace(ActionSpec a, BindingScope scope) async {
    final opener = hooks.openWorkspace;
    if (opener == null) return ActionResult.failure('No workspace host wired');
    final tabId = a.props['tab_id'] as String?;
    final ref = a.props['ref'] as String?;
    final ephemeral = a.props['ephemeral'];
    final ctx = _resolveMap(a.props['ctx'], scope);
    WidgetNode? tree;
    String? title;
    String? icon;
    if (ephemeral is Map) {
      final map = ephemeral.cast<String, dynamic>();
      title = map['title'] as String?;
      icon = map['icon'] as String?;
      final rawTree = map['tree'];
      if (rawTree is Map) {
        tree = WidgetNode.fromJson(rawTree.cast<String, dynamic>());
      }
    }
    opener(
      tabId: tabId,
      tree: tree,
      ref: ref,
      ctx: ctx,
      title: title,
      icon: icon,
    );
    return ActionResult.success();
  }

  Future<ActionResult> _doSetState(ActionSpec a, BindingScope scope) async {
    final set = _resolveMap(a.props['set'], scope);
    if (set == null) return ActionResult.success();
    final scopeKind = (a.props['scope'] as String? ?? 'widget').toLowerCase();
    state.setState(set, scope: scopeKind);
    return ActionResult.success();
  }

  Future<ActionResult> _doRefresh(ActionSpec a, BindingScope scope) async {
    final b = a.props['bindings'];
    if (b is List) {
      for (final name in b) {
        await data.refresh(name.toString());
      }
    } else if (b is String) {
      await data.refresh(b);
    } else {
      await data.refresh('all');
    }
    return ActionResult.success();
  }

  Future<ActionResult> _doCopy(
    ActionSpec a,
    BindingScope scope,
    BuildContext context,
  ) async {
    final text = evalTemplate(a.props['text'] as String? ?? '', scope);
    await Clipboard.setData(ClipboardData(text: text));
    final toast = a.props['toast'] as String?;
    if (toast != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(toast),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return ActionResult.success();
  }

  Future<ActionResult> _doDownload(ActionSpec a, BindingScope scope) async {
    final url = evalTemplate(a.props['url'] as String? ?? '', scope);
    final uri = Uri.tryParse(url);
    if (uri == null) return ActionResult.failure('Invalid URL');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return ActionResult.success();
  }

  Future<ActionResult> _doNavigate(ActionSpec a, BindingScope scope) async {
    final nav = hooks.navigate;
    if (nav == null) return ActionResult.failure('No navigator wired');
    nav(
      appId: a.props['app'] as String?,
      workspaceTab: a.props['workspace_tab'] as String?,
    );
    return ActionResult.success();
  }

  Future<ActionResult> _doConfirm(
    ActionSpec a,
    BuildContext context,
    Map<String, dynamic>? scopeExtra,
  ) async {
    if (!context.mounted) return ActionResult.failure('Context unmounted');
    final scope = state.buildScope(extra: scopeExtra);
    final text = evalTemplate(a.props['text'] as String? ?? '', scope);
    final confirmLabel = a.props['confirm_label'] as String? ?? 'Confirm';
    final cancelLabel = a.props['cancel_label'] as String? ?? 'Cancel';
    final destructive = a.props['destructive'] == true;
    final ok = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            content: Text(text),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(cancelLabel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: destructive ? Colors.red : null,
                ),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return ActionResult.failure('User cancelled');
    final then = a.sub('then');
    if (then == null) return ActionResult.success();
    if (!context.mounted) return ActionResult.failure('Context unmounted');
    return run(then, context: context, scopeExtra: scopeExtra);
  }

  Future<ActionResult> _doSequence(
    ActionSpec a,
    BuildContext context,
    Map<String, dynamic>? scopeExtra,
  ) async {
    final steps = a.subs('steps');
    final stopOnError = a.props['stop_on_error'] != false;
    dynamic last;
    for (final step in steps) {
      if (!context.mounted) {
        return ActionResult.failure('Context unmounted mid-sequence');
      }
      final r = await run(step, context: context, scopeExtra: scopeExtra);
      if (!r.ok && stopOnError) return r;
      last = r.value;
    }
    return ActionResult.success(last);
  }

  // ── helpers ──────────────────────────────────────────────────

  Map<String, dynamic>? _resolveMap(dynamic raw, BindingScope scope) {
    if (raw is! Map) return null;
    final out = <String, dynamic>{};
    raw.forEach((k, v) {
      out[k.toString()] = resolve(v, scope);
    });
    return out;
  }
}
