class AppSummary {
  final String appId;
  final String name;
  final String version;
  final String mode;
  final List<String> agents;
  final List<String> modules;
  final int totalTools;
  final int totalCategories;
  final String workspaceMode;
  final String greeting;

  AppSummary({
    required this.appId,
    required this.name,
    required this.version,
    required this.mode,
    required this.agents,
    required this.modules,
    required this.totalTools,
    required this.totalCategories,
    required this.workspaceMode,
    required this.greeting,
  });

  factory AppSummary.fromJson(Map<String, dynamic> json) {
    return AppSummary(
      appId: json['app_id'] ?? '',
      name: json['name'] ?? '',
      version: json['version'] ?? '',
      mode: json['mode'] ?? '',
      agents: List<String>.from(json['agents'] ?? []),
      modules: List<String>.from(json['modules'] ?? []),
      totalTools: json['total_tools'] ?? 0,
      totalCategories: json['total_categories'] ?? 0,
      workspaceMode: json['workspace_mode'] ?? 'auto',
      greeting: json['greeting'] ?? '',
    );
  }
}
