import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../models/app_summary.dart';
import '../../services/app_bundle_loader.dart';
import '../../services/apps_service.dart';
import '../../theme/app_theme.dart';

/// Full "pick a YAML → deploy → maybe collect secrets → retry" flow,
/// shared between the empty-state Deploy button on the home screen,
/// the sidebar "+" button in the apps popover, and anything else that
/// needs to deploy.
///
/// Returns the deployed [AppSummary] on success, or `null` if the user
/// cancelled the file picker / secrets dialog.
Future<AppSummary?> runDeployFlow(BuildContext context) async {
  final picked = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: 'deploy.app_bundle_type'.tr(),
        extensions: const ['yaml', 'yml', 'zip'],
      ),
    ],
  );
  if (picked == null) return null;

  final rawBytes = await picked.readAsBytes();
  final filename = picked.name;

  if (!context.mounted) return null;

  // Turn the picked file into a bundle (YAML + referenced assets).
  // Raw `.yaml` → bundle with zero assets. `.zip` → bundle built from
  // the archive's contents. Failures here are user errors — surface
  // them in the same copy-friendly dialog as daemon errors.
  final AppBundle bundle;
  try {
    bundle = loadAppBundle(bytes: rawBytes, filename: filename);
  } on AppBundleException catch (e) {
    await _showErrorDialog(context, e.message);
    return null;
  }

  if (!context.mounted) return null;

  final assetMsg = bundle.assets.isEmpty
      ? 'Deploying ${bundle.yamlFilename}…'
      : 'Deploying ${bundle.yamlFilename} '
          '(${bundle.assets.length} assets)…';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(assetMsg),
    duration: const Duration(seconds: 2),
  ));

  return _runDeploy(
    context,
    yamlBytes: bundle.yamlBytes,
    filename: bundle.yamlFilename,
    assets: bundle.assets,
  );
}

/// Internal recursive implementation — each retry calls itself with
/// the newly-collected secrets merged into the previous ones so the
/// user never has to re-type a value. `assets` is passed through
/// unchanged on retries: we don't re-prompt for the bundle contents.
Future<AppSummary?> _runDeploy(
  BuildContext context, {
  required Uint8List yamlBytes,
  required String filename,
  Map<String, String>? secrets,
  Map<String, String>? assets,
}) async {
  try {
    final deployed = await AppsService().deploy(
      yamlBytes: yamlBytes,
      filename: filename,
      secrets: secrets,
      assets: assets,
    );
    if (!context.mounted) return deployed;
    final c = context.colors;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('deploy.deployed_success'
          .tr(namedArgs: {'name': deployed.name})),
      backgroundColor: c.green.withValues(alpha: 0.9),
    ));
    return deployed;
  } on DeployException catch (e) {
    if (!context.mounted) return null;

    // Missing env vars → prompt then retry.
    if (e.needsSecrets) {
      final collected = await _promptForSecrets(context, e.missingSecrets);
      if (collected == null || !context.mounted) return null;
      return _runDeploy(
        context,
        yamlBytes: yamlBytes,
        filename: filename,
        assets: assets,
        secrets: {
          if (secrets != null) ...secrets,
          ...collected,
        },
      );
    }

    await _showErrorDialog(context, e.message);
    return null;
  }
}

/// Shows a themed, copy-friendly error dialog for a failed deploy.
/// The daemon typically returns multi-line compilation errors — a
/// snackbar truncates them, so we use an AlertDialog with a
/// [SelectableText] body plus a dedicated Copy button.
Future<void> _showErrorDialog(BuildContext context, String error) async {
  final c = context.colors;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.red),
          const SizedBox(width: 10),
          Text('deploy.failed_title'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.border),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              error,
              style: GoogleFonts.firaCode(
                fontSize: 11.5,
                color: c.text,
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: error));
            if (!ctx.mounted) return;
            // Confirm the copy briefly inside the dialog itself.
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text('deploy.error_copied'.tr()),
              duration: const Duration(seconds: 2),
              backgroundColor: c.green.withValues(alpha: 0.9),
            ));
          },
          icon: Icon(Icons.copy_rounded, size: 14, color: c.textMuted),
          label: Text('common.copy'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.textMuted)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx),
          style: ElevatedButton.styleFrom(
            backgroundColor: c.red,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6)),
          ),
          child: Text('common.close'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}

/// Modal dialog that asks the user for a secret value per missing
/// env var. All fields are obscured. Returns the collected map or
/// `null` if cancelled.
Future<Map<String, String>?> _promptForSecrets(
  BuildContext context,
  List<String> names,
) async {
  final controllers = {
    for (final n in names) n: TextEditingController(),
  };
  final result = await showDialog<Map<String, String>>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final c = ctx.colors;
      return AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.key_rounded, size: 16, color: c.orange),
            const SizedBox(width: 8),
            Text('deploy.secrets_required'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.textBright)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The YAML references environment variables that are not '
                'set on the daemon. Provide values for each — they will be '
                'stored daemon-side, not in the YAML.',
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted, height: 1.45),
              ),
              const SizedBox(height: 16),
              for (final name in names) ...[
                Text(name,
                    style: GoogleFonts.firaCode(
                        fontSize: 11,
                        color: c.textBright,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                TextField(
                  controller: controllers[name],
                  obscureText: true,
                  style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: c.bg,
                    hintText: '•••••••••',
                    hintStyle:
                        GoogleFonts.firaCode(fontSize: 12, color: c.textDim),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: c.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: c.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: c.blue)),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text('common.cancel'.tr(),
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              final values = <String, String>{};
              for (final n in names) {
                final v = controllers[n]!.text;
                if (v.isNotEmpty) values[n] = v;
              }
              Navigator.pop(ctx, values);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: c.blue,
              foregroundColor: Colors.white,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            child: Text('dashboard.deploy'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      );
    },
  );
  for (final c in controllers.values) {
    c.dispose();
  }
  return result;
}
