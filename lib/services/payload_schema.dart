/// Typed parser for the `payload_schema` block returned by
/// `GET /api/apps/{id}` for background apps.
///
/// All fields are tolerant of missing keys, defaulting to safe values
/// so a daemon that omits an optional flag never crashes the form.
/// The widgets in `lib/ui/background/widgets/typed_payload_form.dart`
/// drive the actual rendering.
library;

class PayloadSchema {
  /// Whether the payload must be valid before a session can activate.
  /// When false, the user can submit an incomplete payload at their
  /// own risk; when true, the Activate button stays disabled until
  /// `validation.valid == true`.
  final bool required;

  final PromptConfig? prompt;
  final List<MetadataField> metadata;
  final List<FileSlot> files;

  const PayloadSchema({
    this.required = false,
    this.prompt,
    this.metadata = const [],
    this.files = const [],
  });

  bool get isEmpty =>
      prompt == null && metadata.isEmpty && files.isEmpty;

  /// Parse the raw map straight from the daemon. Returns `null` when
  /// the input is null, missing, or not a Map (i.e. the app didn't
  /// declare a schema and the client should fall back to the generic
  /// editor).
  static PayloadSchema? parse(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();

    PromptConfig? prompt;
    final p = j['prompt'];
    if (p is Map) {
      prompt = PromptConfig.fromJson(p.cast<String, dynamic>());
    }

    final metaList = (j['metadata'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => MetadataField.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);

    final fileList = (j['files'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => FileSlot.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);

    return PayloadSchema(
      required: j['required'] == true,
      prompt: prompt,
      metadata: metaList,
      files: fileList,
    );
  }
}

/// Configuration for the free-text prompt at the top of the typed
/// form. When absent (`PayloadSchema.prompt == null`), the prompt
/// section is hidden entirely.
class PromptConfig {
  final bool required;
  final String label;
  final String placeholder;
  final String description;
  final String defaultValue;
  final int? minLength;
  final int? maxLength;

  const PromptConfig({
    this.required = false,
    this.label = 'Prompt',
    this.placeholder = '',
    this.description = '',
    this.defaultValue = '',
    this.minLength,
    this.maxLength,
  });

  factory PromptConfig.fromJson(Map<String, dynamic> j) => PromptConfig(
        required: j['required'] == true,
        label: j['label'] as String? ?? 'Prompt',
        placeholder: j['placeholder'] as String? ?? '',
        description: j['description'] as String? ?? '',
        defaultValue: j['default'] as String? ?? '',
        minLength: (j['min_length'] as num?)?.toInt(),
        maxLength: (j['max_length'] as num?)?.toInt(),
      );

  /// Validates [value] against the schema's constraints and returns a
  /// human-readable error or `null` when ok.
  String? validate(String value) {
    final trimmed = value.trim();
    if (required && trimmed.isEmpty) return 'Required';
    if (minLength != null && trimmed.length < minLength!) {
      return 'Min $minLength characters';
    }
    if (maxLength != null && value.length > maxLength!) {
      return 'Max $maxLength characters';
    }
    return null;
  }
}

/// One typed metadata field declared by the schema. The `type` drives
/// the widget choice; everything else is shared validation metadata.
class MetadataField {
  final String name;
  final String label;
  /// `string` | `text` | `integer` | `number` | `boolean` | `select`
  final String type;
  final bool required;
  final dynamic defaultValue;
  final String? description;
  final String? placeholder;
  final List<String> options;
  final num? min;
  final num? max;

  const MetadataField({
    required this.name,
    this.label = '',
    required this.type,
    this.required = false,
    this.defaultValue,
    this.description,
    this.placeholder,
    this.options = const [],
    this.min,
    this.max,
  });

  factory MetadataField.fromJson(Map<String, dynamic> j) => MetadataField(
        name: j['name'] as String? ?? '',
        // Fall back to a Title Case version of `name` when no label.
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? j['label'] as String
            : _humanise(j['name'] as String? ?? ''),
        type: j['type'] as String? ?? 'string',
        required: j['required'] == true,
        defaultValue: j['default'],
        description: j['description'] as String?,
        placeholder: j['placeholder'] as String?,
        options: (j['options'] as List? ?? const [])
            .whereType<Object>()
            .map((e) => e.toString())
            .toList(growable: false),
        min: j['min'] as num?,
        max: j['max'] as num?,
      );

  /// Best-effort coercion of the user's text input to the right type
  /// before sending to the daemon.
  dynamic coerce(dynamic raw) {
    if (raw == null) return null;
    final text = raw is String ? raw.trim() : raw.toString();
    switch (type) {
      case 'integer':
        return int.tryParse(text);
      case 'number':
        return double.tryParse(text);
      case 'boolean':
        if (raw is bool) return raw;
        return text == 'true' || text == '1' || text == 'yes';
      default:
        return text;
    }
  }

  /// Validates a coerced value. Returns an error string or null.
  String? validate(dynamic value) {
    if (required) {
      if (value == null) return 'Required';
      if (value is String && value.isEmpty) return 'Required';
    }
    if (value == null) return null;
    if (type == 'integer' || type == 'number') {
      final n = value is num ? value : null;
      if (n == null) return 'Invalid number';
      if (min != null && n < min!) return 'Min $min';
      if (max != null && n > max!) return 'Max $max';
    }
    if (type == 'select' && value is String && value.isNotEmpty) {
      if (options.isNotEmpty && !options.contains(value)) {
        return 'Pick one of: ${options.join(", ")}';
      }
    }
    return null;
  }

  static String _humanise(String snake) {
    if (snake.isEmpty) return '';
    return snake
        .split('_')
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }
}

/// Logical "slot" for one or more uploaded files. The daemon doesn't
/// track which slot a file belongs to — the client matches by mime
/// type. A `cv` slot accepting only `application/pdf` will pull every
/// uploaded PDF into its slot widget.
class FileSlot {
  final String name;
  final String label;
  final String? description;
  final bool required;
  final List<String> mime;
  final double maxSizeMb;
  final int maxCount;

  const FileSlot({
    required this.name,
    this.label = '',
    this.description,
    this.required = false,
    this.mime = const [],
    this.maxSizeMb = 25,
    this.maxCount = 1,
  });

  factory FileSlot.fromJson(Map<String, dynamic> j) => FileSlot(
        name: j['name'] as String? ?? '',
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? j['label'] as String
            : MetadataField._humanise(j['name'] as String? ?? ''),
        description: j['description'] as String?,
        required: j['required'] == true,
        mime: (j['mime'] as List? ?? const [])
            .whereType<Object>()
            .map((e) => e.toString())
            .toList(growable: false),
        maxSizeMb: (j['max_size_mb'] as num?)?.toDouble() ?? 25,
        maxCount: (j['max_count'] as num?)?.toInt() ?? 1,
      );

  /// Matches an uploaded file's mime type against this slot's accepted
  /// list. `["image/*"]` matches any `image/png`, `image/jpeg`, etc.
  /// An empty list matches everything.
  bool acceptsMime(String mimeType) {
    if (mime.isEmpty) return true;
    final actual = mimeType.toLowerCase();
    for (final pattern in mime) {
      final p = pattern.toLowerCase();
      if (p == actual) return true;
      if (p.endsWith('/*')) {
        final prefix = p.substring(0, p.length - 1);
        if (actual.startsWith(prefix)) return true;
      }
    }
    return false;
  }

  /// File-selector compatible extension list — used to constrain the
  /// native picker. Returns null when [mime] is empty (any file ok).
  List<String>? get acceptedExtensions {
    if (mime.isEmpty) return null;
    final out = <String>[];
    for (final p in mime) {
      switch (p.toLowerCase()) {
        case 'application/pdf':
          out.add('pdf');
          break;
        case 'application/json':
          out.add('json');
          break;
        case 'application/zip':
          out.add('zip');
          break;
        case 'text/plain':
          out.add('txt');
          break;
        case 'text/csv':
          out.add('csv');
          break;
        case 'image/*':
          out.addAll(['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']);
          break;
        case 'image/png':
          out.add('png');
          break;
        case 'image/jpeg':
          out.add('jpg');
          out.add('jpeg');
          break;
        default:
          // Best-effort: derive an extension from the subtype.
          final slash = p.indexOf('/');
          if (slash > 0 && !p.endsWith('*')) {
            out.add(p.substring(slash + 1));
          }
      }
    }
    return out.isEmpty ? null : out;
  }
}

/// Server-side validation block returned alongside `GET /payload`
/// when the app declares a schema. The client uses [valid] to gate
/// the Activate button and [errors] to display inline messages.
class PayloadValidation {
  final bool schemaRequired;
  final bool valid;
  final List<String> errors;

  const PayloadValidation({
    this.schemaRequired = false,
    this.valid = true,
    this.errors = const [],
  });

  static const empty = PayloadValidation();

  bool get blocksActivation => schemaRequired && !valid;

  factory PayloadValidation.fromJson(Map<String, dynamic> j) =>
      PayloadValidation(
        schemaRequired: j['schema_required'] == true,
        valid: j['valid'] == true,
        errors: (j['errors'] as List? ?? const [])
            .whereType<Object>()
            .map((e) => e.toString())
            .toList(growable: false),
      );
}
