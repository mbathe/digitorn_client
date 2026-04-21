/// Client-side canvas for `render_mode: builder` apps (digitorn-builder
/// and any other app that wants a derived-graph view instead of a
/// live web preview).
///
/// What it does:
///   1. Parses `app.yaml` from `WorkspaceModule.files` on every change.
///   2. Derives nodes (triggers / agents / modules) and edges
///      (capabilities.grant → agent-to-module arrows).
///   3. Overlays live state:
///        * `_state/progress.json`  → phase indicator
///        * `_state/compile.json`   → compile errors
///        * `_state/deploy.json`    → deploy status
///        * `_state/tests.json`     → test status badges
///   4. Re-renders as soon as the daemon ships a new
///      `preview:resource_*` event; no RPC, no polling.
///
/// The daemon stays agnostic about what a "builder app" looks like —
/// it just ferries files. All derivation lives here, which means the
/// same wire can host any future canvas shape (task board, sequence
/// diagram, topology view, …) without daemon changes.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:yaml/yaml.dart';

import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';

class BuilderCanvas extends StatelessWidget {
  const BuilderCanvas({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WorkspaceModule(),
      builder: (context, _) {
        final module = WorkspaceModule();
        final appYaml = module.files['app.yaml']?.content ?? '';
        final progress = _readJsonFile(module, '_state/progress.json');
        final compile = _readJsonFile(module, '_state/compile.json');
        final deploy = _readJsonFile(module, '_state/deploy.json');
        final tests = _readJsonFile(module, '_state/tests.json');

        if (appYaml.trim().isEmpty) {
          return const _EmptyState();
        }

        final graph = _parseAppYaml(appYaml);
        if (graph == null) {
          return const _ParseErrorState();
        }

        return _CanvasBody(
          graph: graph,
          progress: progress,
          compile: compile,
          deploy: deploy,
          tests: tests,
        );
      },
    );
  }

  static Map<String, dynamic>? _readJsonFile(
      WorkspaceModule module, String path) {
    final content = module.files[path]?.content;
    if (content == null || content.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // Ignore parse errors — state files are best-effort overlays.
    }
    return null;
  }
}

// ─── YAML → graph parser ──────────────────────────────────────────

class _Graph {
  final String appName;
  final String? title;
  final List<_Trigger> triggers;
  final List<_Agent> agents;
  final List<_Module> modules;
  /// Map of agent-id → list of modules granted. Forms the edges.
  final Map<String, List<String>> grants;

  const _Graph({
    required this.appName,
    required this.title,
    required this.triggers,
    required this.agents,
    required this.modules,
    required this.grants,
  });
}

class _Trigger {
  final String type;
  final String? detail;
  const _Trigger({required this.type, this.detail});
}

class _Agent {
  final String id;
  final String? role;
  final String? brain;
  const _Agent({required this.id, this.role, this.brain});
}

class _Module {
  final String name;
  final String? config;
  const _Module({required this.name, this.config});
}

_Graph? _parseAppYaml(String source) {
  dynamic doc;
  try {
    doc = loadYaml(source);
  } catch (_) {
    return null;
  }
  if (doc is! YamlMap) return null;

  final appName = (doc['app'] is YamlMap
          ? (doc['app'] as YamlMap)['id']?.toString()
          : null) ??
      doc['name']?.toString() ??
      doc['id']?.toString() ??
      '';
  final title = doc['title']?.toString() ??
      (doc['app'] is YamlMap
          ? (doc['app'] as YamlMap)['name']?.toString()
          : null);

  // Triggers — three shapes observed in the wild:
  //   1. `execution.triggers:` as a YamlList (older schema)
  //   2. Top-level `triggers:` as a YamlMap keyed by trigger name
  //      (the shape the builder scaffolds by default)
  //   3. Top-level `triggers:` as a YamlList
  final triggers = <_Trigger>[];
  void addTriggerMap(String key, YamlMap m) {
    triggers.add(_Trigger(
      type: (m['type'] ?? key).toString(),
      detail: m['cron']?.toString() ??
          m['event']?.toString() ??
          m['path']?.toString() ??
          m['schedule']?.toString() ??
          m['description']?.toString(),
    ));
  }
  void addTriggerList(YamlList list) {
    for (final t in list) {
      if (t is YamlMap) {
        addTriggerMap((t['id'] ?? t['name'] ?? '').toString(), t);
      } else if (t is String) {
        triggers.add(_Trigger(type: t));
      }
    }
  }
  final execution = doc['execution'];
  if (execution is YamlMap && execution['triggers'] is YamlList) {
    addTriggerList(execution['triggers'] as YamlList);
  }
  final topTriggers = doc['triggers'];
  if (topTriggers is YamlList) {
    addTriggerList(topTriggers);
  } else if (topTriggers is YamlMap) {
    for (final entry in topTriggers.entries) {
      final v = entry.value;
      if (v is YamlMap) {
        addTriggerMap(entry.key.toString(), v);
      } else {
        triggers.add(_Trigger(type: entry.key.toString(), detail: v?.toString()));
      }
    }
  }

  // Agents — brain can be a string or a `{provider, model}` map
  // (the digitorn-builder shape). Flatten to `provider/model` so
  // the card shows something meaningful.
  String? flattenBrain(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return raw;
    if (raw is YamlMap) {
      final provider = raw['provider']?.toString();
      final model = raw['model']?.toString();
      if (provider != null && model != null) return '$provider/$model';
      return (model ?? provider);
    }
    return raw.toString();
  }
  final agents = <_Agent>[];
  final agentsRaw = doc['agents'];
  if (agentsRaw is YamlList) {
    for (final a in agentsRaw) {
      if (a is YamlMap) {
        agents.add(_Agent(
          id: (a['id'] ?? a['name'] ?? '?').toString(),
          role: a['role']?.toString(),
          brain: flattenBrain(a['brain']) ?? flattenBrain(a['model']),
        ));
      } else if (a is String) {
        agents.add(_Agent(id: a));
      }
    }
  }

  // Modules
  final modules = <_Module>[];
  final modulesRaw = doc['modules'];
  if (modulesRaw is YamlMap) {
    for (final entry in modulesRaw.entries) {
      final name = entry.key.toString();
      String? cfg;
      final v = entry.value;
      if (v is YamlMap && v.isNotEmpty) {
        cfg = v.entries
            .take(2)
            .map((e) => '${e.key}=${e.value}')
            .join(', ');
      }
      modules.add(_Module(name: name, config: cfg));
    }
  } else if (modulesRaw is YamlList) {
    for (final m in modulesRaw) {
      modules.add(_Module(name: m.toString()));
    }
  }

  // Capabilities → edges. Accepts three shapes:
  //   { agent: X, module: Y }            — scoped grant
  //   { module: Y }                       — global (applies to all agents)
  //   "module-name"                       — shorthand for global grant
  // Global grants are fanned out to every declared agent so each
  // agent card shows the module as a linked dependency.
  final grants = <String, List<String>>{};
  final globalModules = <String>[];
  void addGrant(String? agent, String module) {
    if (agent == null || agent.isEmpty) {
      globalModules.add(module);
    } else {
      grants.putIfAbsent(agent, () => []).add(module);
    }
  }
  final capabilities = doc['capabilities'];
  if (capabilities is YamlMap) {
    final grantList = capabilities['grant'];
    if (grantList is YamlList) {
      for (final g in grantList) {
        if (g is YamlMap) {
          final module = g['module']?.toString();
          if (module == null || module.isEmpty) continue;
          addGrant(g['agent']?.toString(), module);
        } else if (g is String) {
          addGrant(null, g);
        }
      }
    }
  }
  if (globalModules.isNotEmpty) {
    for (final agent in agents) {
      grants.putIfAbsent(agent.id, () => []).addAll(globalModules);
    }
  }

  return _Graph(
    appName: appName,
    title: title,
    triggers: triggers,
    agents: agents,
    modules: modules,
    grants: grants,
  );
}

// ─── Canvas UI ────────────────────────────────────────────────────

class _CanvasBody extends StatelessWidget {
  final _Graph graph;
  final Map<String, dynamic>? progress;
  final Map<String, dynamic>? compile;
  final Map<String, dynamic>? deploy;
  final Map<String, dynamic>? tests;

  const _CanvasBody({
    required this.graph,
    required this.progress,
    required this.compile,
    required this.deploy,
    required this.tests,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          _CanvasHeader(graph: graph, progress: progress),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _ColumnSection(
                      icon: Icons.flash_on_rounded,
                      title: 'Triggers',
                      accent: c.blue,
                      empty: 'No triggers defined.',
                      children: graph.triggers
                          .map((t) => _TriggerCard(trigger: t))
                          .toList(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ColumnSection(
                      icon: Icons.smart_toy_rounded,
                      title: 'Agents',
                      accent: c.accentPrimary,
                      empty: 'No agents yet.',
                      children: graph.agents
                          .map((a) => _AgentCard(
                                agent: a,
                                grantedModules: graph.grants[a.id] ?? const [],
                              ))
                          .toList(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ColumnSection(
                      icon: Icons.extension_rounded,
                      title: 'Modules',
                      accent: c.green,
                      empty: 'No modules configured.',
                      children: graph.modules
                          .map((m) => _ModuleCard(module: m))
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _CanvasFooter(
            compile: compile,
            deploy: deploy,
            tests: tests,
          ),
        ],
      ),
    );
  }
}

class _CanvasHeader extends StatelessWidget {
  final _Graph graph;
  final Map<String, dynamic>? progress;

  const _CanvasHeader({required this.graph, required this.progress});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final phase = (progress?['current_step'] ??
            progress?['step'] ??
            progress?['phase']) as int?;
    final total = (progress?['total_steps'] ??
            progress?['total'] ??
            progress?['phases']) as int?;
    final phaseLabel = progress?['description']?.toString() ??
        progress?['label']?.toString() ??
        '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.hub_rounded, size: 15, color: c.accentPrimary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              graph.title?.isNotEmpty == true
                  ? graph.title!
                  : (graph.appName.isNotEmpty ? graph.appName : 'Application'),
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: c.text,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          if (graph.appName.isNotEmpty &&
              graph.title?.isNotEmpty == true &&
              graph.appName != graph.title)
            Text(
              graph.appName,
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
            ),
          const Spacer(),
          if (phase != null || total != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.accentPrimary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: c.accentPrimary.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.timeline_rounded,
                      size: 11, color: c.accentPrimary),
                  const SizedBox(width: 5),
                  Text(
                    'Phase ${phase ?? '?'}${total != null ? ' / $total' : ''}'
                    '${phaseLabel.isNotEmpty ? ' — $phaseLabel' : ''}',
                    style: GoogleFonts.inter(
                      fontSize: 10.5,
                      color: c.accentPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CanvasFooter extends StatelessWidget {
  final Map<String, dynamic>? compile;
  final Map<String, dynamic>? deploy;
  final Map<String, dynamic>? tests;

  const _CanvasFooter({
    required this.compile,
    required this.deploy,
    required this.tests,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final compileErrors = (compile?['errors'] as List?)?.length ?? 0;
    final compileOk = compile != null && compileErrors == 0;
    final testsPassed = (tests?['passed'] ?? tests?['pass']) as int?;
    final testsTotal = (tests?['total'] ?? tests?['count']) as int?;
    final deployStatus = deploy?['status']?.toString() ??
        deploy?['environment']?.toString();

    final chips = <Widget>[
      if (compile != null)
        _StatusChip(
          icon: compileOk
              ? Icons.check_circle_outline
              : Icons.error_outline,
          label: compileOk
              ? 'Compile OK'
              : '$compileErrors compile error'
                  '${compileErrors == 1 ? '' : 's'}',
          color: compileOk ? c.green : c.red,
        ),
      if (testsPassed != null || testsTotal != null)
        _StatusChip(
          icon: Icons.science_outlined,
          label: testsTotal != null
              ? 'Tests ${testsPassed ?? 0}/$testsTotal'
              : 'Tests ${testsPassed ?? 0}',
          color: (testsPassed ?? 0) == (testsTotal ?? 0) && testsTotal != null
              ? c.green
              : c.orange,
        ),
      if (deployStatus != null)
        _StatusChip(
          icon: Icons.rocket_launch_outlined,
          label: 'Deploy: $deployStatus',
          color: deployStatus.toLowerCase().contains('prod')
              ? c.green
              : c.blue,
        ),
    ];

    if (chips.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: chips,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ColumnSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color accent;
  final String empty;
  final List<Widget> children;

  const _ColumnSection({
    required this.icon,
    required this.title,
    required this.accent,
    required this.empty,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: accent),
              const SizedBox(width: 6),
              Text(
                title.toUpperCase(),
                style: GoogleFonts.inter(
                  fontSize: 10,
                  color: accent,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                '${children.length}',
                style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: c.textDim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                empty,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: c.textDim,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...children.expand((w) => [w, const SizedBox(height: 8)]),
        ],
      ),
    );
  }
}

class _TriggerCard extends StatelessWidget {
  final _Trigger trigger;
  const _TriggerCard({required this.trigger});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Text(
            trigger.type,
            style: GoogleFonts.firaCode(
              fontSize: 11,
              color: c.blue,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trigger.detail != null && trigger.detail!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                trigger.detail!,
                style:
                    GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  final _Agent agent;
  final List<String> grantedModules;

  const _AgentCard({
    required this.agent,
    required this.grantedModules,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_outline_rounded,
                  size: 12, color: c.accentPrimary),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  agent.id,
                  style: GoogleFonts.firaCode(
                    fontSize: 11.5,
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (agent.role != null && agent.role!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              agent.role!,
              style: GoogleFonts.inter(fontSize: 10, color: c.textDim),
            ),
          ],
          if (agent.brain != null && agent.brain!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '🧠 ${agent.brain}',
              style: GoogleFonts.firaCode(fontSize: 9.5, color: c.textDim),
            ),
          ],
          if (grantedModules.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final m in grantedModules)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: c.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '→ $m',
                      style: GoogleFonts.firaCode(
                        fontSize: 9.5,
                        color: c.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  final _Module module;
  const _ModuleCard({required this.module});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            module.name,
            style: GoogleFonts.firaCode(
              fontSize: 11,
              color: c.green,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (module.config != null && module.config!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              module.config!,
              style: GoogleFonts.firaCode(fontSize: 9.5, color: c.textDim),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.bg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 32, color: c.textDim),
          const SizedBox(height: 12),
          Text(
            'The canvas renders here once the agent creates app.yaml.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 12, color: c.textDim),
          ),
          const SizedBox(height: 4),
          Text(
            'Ask the agent to start building your app.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 11, color: c.textDim),
          ),
        ],
      ),
    );
  }
}

class _ParseErrorState extends StatelessWidget {
  const _ParseErrorState();
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.bg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 28, color: c.orange),
          const SizedBox(height: 12),
          Text(
            'app.yaml is not valid YAML yet',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: c.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'The canvas will re-render as soon as the file parses cleanly.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 11, color: c.textDim),
          ),
        ],
      ),
    );
  }
}
