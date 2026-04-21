/// UI-safe configuration returned by `GET /api/apps/{id}/ui-config`.
///
/// The daemon allow-lists fields with `_WS_ALLOW` / `_PREVIEW_ALLOW`
/// to keep prompts / api_keys / secrets / hooks server-side. This
/// model surfaces only what the client legitimately needs to wire
/// UI decisions: render_mode, auto_approve flag, preview enablement.
///
/// Scout-verified on daemon commit incl. BUG #1/#2/#20 fixes.
library;

class AppUiConfig {
  final String appId;
  final WorkspaceConfig workspace;
  final PreviewConfig preview;

  const AppUiConfig({
    required this.appId,
    required this.workspace,
    required this.preview,
  });

  factory AppUiConfig.fromJson(Map<String, dynamic> json) {
    // Scout-verified shape (3 top-level blocks):
    //   workspace_config  — full superset (auto_approve, sync_to_disk,
    //                        lint, render_mode, entry_file, title)
    //   workspace         — public-face subset (render_mode, entry_file,
    //                        title) — useful when the daemon wants to
    //                        keep the auto_approve flag server-side
    //   preview_config    — preview.enabled, preview.port
    //
    // We merge `workspace` INTO `workspace_config` so the client sees
    // a single resolved struct. `workspace_config` wins on shared keys
    // (it's authoritative); `workspace` fills any gaps.
    final wsConfig =
        (json['workspace_config'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final wsBlock = (json['workspace'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final merged = <String, dynamic>{...wsBlock, ...wsConfig};
    final pv = (json['preview_config'] as Map?)?.cast<String, dynamic>() ??
        (json['preview'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    return AppUiConfig(
      appId: (json['app_id'] as String?) ?? '',
      workspace: WorkspaceConfig.fromJson(merged),
      preview: PreviewConfig.fromJson(pv),
    );
  }

  /// Empty defaults — used while the fetch is in-flight or when the
  /// app predates the `/ui-config` endpoint. Auto-approve is FALSE
  /// by default (safest UI: always show approve/reject controls).
  const AppUiConfig.empty()
      : appId = '',
        workspace = const WorkspaceConfig.empty(),
        preview = const PreviewConfig.empty();
}

class WorkspaceConfig {
  final String? renderMode;
  final String? entryFile;
  final String? title;
  final bool? syncToDisk;
  final bool? lint;
  final bool autoApprove;

  const WorkspaceConfig({
    this.renderMode,
    this.entryFile,
    this.title,
    this.syncToDisk,
    this.lint,
    this.autoApprove = false,
  });

  const WorkspaceConfig.empty()
      : renderMode = null,
        entryFile = null,
        title = null,
        syncToDisk = null,
        lint = null,
        autoApprove = false;

  factory WorkspaceConfig.fromJson(Map<String, dynamic> json) {
    return WorkspaceConfig(
      renderMode: json['render_mode'] as String?,
      entryFile: json['entry_file'] as String?,
      title: json['title'] as String?,
      syncToDisk: json['sync_to_disk'] as bool?,
      lint: json['lint'] as bool?,
      autoApprove: (json['auto_approve'] as bool?) ?? false,
    );
  }
}

class PreviewConfig {
  final bool enabled;
  final int? port;

  const PreviewConfig({this.enabled = false, this.port});

  const PreviewConfig.empty()
      : enabled = false,
        port = null;

  factory PreviewConfig.fromJson(Map<String, dynamic> json) {
    return PreviewConfig(
      enabled: (json['enabled'] as bool?) ?? false,
      port: (json['port'] as num?)?.toInt(),
    );
  }
}
