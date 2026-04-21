import 'package:flutter/material.dart';
import 'package:xml/xml.dart';
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';
import 'structured/structured_data_viewer.dart';

/// XML viewer — thin wrapper around [StructuredDataViewer] that
/// normalises an XML document into a plain `Map`/`List`/scalar tree
/// using a "BadgerFish-lite" convention so the shared structured
/// viewer can render it.
///
/// Conventions:
/// - The whole document is wrapped in `{rootTagName: …}`.
/// - Each element becomes a Map.
/// - Attributes are stored under keys prefixed by `@` (e.g. `@id`).
/// - Element text content is stored under the key `#text`.
/// - When an element only has text and no attributes / children, it
///   collapses to that scalar string.
/// - When an element has multiple children sharing the same tag, those
///   children are emitted as a `List`.
/// - Comments and processing instructions are skipped.
/// - Namespaces are stripped (we keep only the local name) so the tree
///   stays readable.
class XmlFileViewer extends FileViewer with SearchableViewer {
  const XmlFileViewer();

  @override
  String get id => 'xml';

  @override
  int get priority => 100;

  @override
  Set<String> get extensions => const {'xml', 'xsd', 'xsl', 'xslt', 'svg', 'rss', 'atom', 'plist'};

  @override
  bool canHandle(buffer) {
    final ext = buffer.extension.toLowerCase();
    // Don't claim SVG when it's used as an image — the ImageFileViewer
    // (priority 50) handles that. Only claim svg here if the user
    // *somehow* registers us at higher priority and wants the tree
    // representation. With the registration order in main.dart, the
    // image viewer wins for `.svg` because resolution is sequential
    // priority-then-registration.
    return extensions.contains(ext) && ext != 'svg';
  }

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    dynamic decoded;
    String? parseError;
    try {
      final doc = XmlDocument.parse(vctx.buffer.content);
      decoded = _documentToPlain(doc);
    } catch (e) {
      parseError = e.toString();
    }
    return StructuredDataViewer(
      key: ValueKey('xml-${vctx.buffer.path}'),
      filename: vctx.buffer.filename,
      rawContent: vctx.buffer.content,
      decodedValue: decoded,
      parseError: parseError,
      badgeLabel: 'XML',
      badgeColorOf: (AppColors c) => c.green,
      rawLanguage: 'xml',
    );
  }
}

// ─── BadgerFish-lite normaliser ────────────────────────────────────────────

dynamic _documentToPlain(XmlDocument doc) {
  final root = doc.rootElement;
  return {root.name.local: _elementToPlain(root)};
}

dynamic _elementToPlain(XmlElement el) {
  final result = <String, dynamic>{};

  // Attributes (with @ prefix)
  for (final attr in el.attributes) {
    result['@${attr.name.local}'] = attr.value;
  }

  // Children: group elements by local tag name
  final byTag = <String, List<dynamic>>{};
  final textBuf = StringBuffer();

  for (final node in el.children) {
    if (node is XmlElement) {
      final name = node.name.local;
      byTag.putIfAbsent(name, () => []).add(_elementToPlain(node));
    } else if (node is XmlText) {
      final t = node.value.trim();
      if (t.isNotEmpty) {
        if (textBuf.isNotEmpty) textBuf.write(' ');
        textBuf.write(t);
      }
    } else if (node is XmlCDATA) {
      final t = node.value.trim();
      if (t.isNotEmpty) {
        if (textBuf.isNotEmpty) textBuf.write(' ');
        textBuf.write(t);
      }
    }
    // Comments and processing instructions are intentionally skipped.
  }

  // Insert text content under #text if present.
  final text = textBuf.toString();
  if (text.isNotEmpty) {
    result['#text'] = text;
  }

  // Collapse {tag: [single]} → {tag: single}
  byTag.forEach((name, list) {
    if (list.length == 1) {
      result[name] = list.first;
    } else {
      result[name] = list;
    }
  });

  // Pure-text element with no attributes → collapse to scalar.
  if (result.length == 1 && result.containsKey('#text')) {
    return result['#text'];
  }

  // Empty element with no attributes / children → null.
  if (result.isEmpty) return null;

  return result;
}
