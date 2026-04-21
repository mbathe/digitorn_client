import '../../../services/workspace_module.dart';
import '../../../services/workspace_service.dart';

/// A single searchable file. Wraps either a workbench buffer or a
/// workspace-module file so the search engine doesn't have to know
/// about the two sources.
class SearchableFile {
  final String path;
  final String filename;
  final String content;
  const SearchableFile({
    required this.path,
    required this.filename,
    required this.content,
  });

  factory SearchableFile.fromBuffer(WorkbenchBuffer b) => SearchableFile(
        path: b.path,
        filename: b.filename,
        content: b.content,
      );

  factory SearchableFile.fromWorkspaceFile(WorkspaceFile f) => SearchableFile(
        path: f.path,
        filename: f.filename,
        content: f.content,
      );
}

/// Merge workbench buffers and workspace-module files into a single
/// list, de-duplicated by path. Buffers win on conflict — their
/// content tends to be fresher because they also pick up edits made
/// through the workbench stream, not only via preview events.
List<SearchableFile> collectSearchableFiles({
  required List<WorkbenchBuffer> buffers,
  required Iterable<WorkspaceFile> moduleFiles,
}) {
  final seen = <String>{};
  final out = <SearchableFile>[];
  for (final b in buffers) {
    if (b.content.isEmpty) continue;
    if (seen.add(b.path)) out.add(SearchableFile.fromBuffer(b));
  }
  for (final f in moduleFiles) {
    if (f.content.isEmpty) continue;
    if (seen.add(f.path)) out.add(SearchableFile.fromWorkspaceFile(f));
  }
  return out;
}

/// User-tunable knobs for a search.
class SearchOptions {
  final String query;
  final bool caseSensitive;
  final bool wholeWord;
  final bool regex;

  const SearchOptions({
    required this.query,
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regex = false,
  });

  bool get isEmpty => query.isEmpty;

  SearchOptions copyWith({
    String? query,
    bool? caseSensitive,
    bool? wholeWord,
    bool? regex,
  }) =>
      SearchOptions(
        query: query ?? this.query,
        caseSensitive: caseSensitive ?? this.caseSensitive,
        wholeWord: wholeWord ?? this.wholeWord,
        regex: regex ?? this.regex,
      );
}

/// One match inside one buffer. Positions are 1-based to align with
/// the rest of the workspace (diagnostics, reveal, line numbers).
class SearchHit {
  final String path;
  final String filename;
  final int line;          // 1-based line in the buffer
  final int column;        // 1-based column at the start of the match
  final int matchLength;
  final String lineContent;

  const SearchHit({
    required this.path,
    required this.filename,
    required this.line,
    required this.column,
    required this.matchLength,
    required this.lineContent,
  });

  /// Zero-based start within [lineContent], for substring extraction.
  int get matchStart => column - 1;
  int get matchEnd => matchStart + matchLength;
}

/// Aggregated result of [searchBuffers]. Hits are kept in their
/// natural traversal order (file order from the input list, then top-down
/// inside each file). The grouped map preserves insertion order.
class SearchResults {
  final List<SearchHit> hits;
  final Map<String, List<SearchHit>> byFile;
  final int fileCount;
  final int totalHits;
  /// Non-null when [SearchOptions.regex] is true and the pattern failed
  /// to compile — the UI surfaces this message instead of an empty list.
  final String? regexError;

  const SearchResults({
    required this.hits,
    required this.byFile,
    required this.fileCount,
    required this.totalHits,
    this.regexError,
  });

  static const empty = SearchResults(
    hits: [],
    byFile: {},
    fileCount: 0,
    totalHits: 0,
  );

  bool get hasError => regexError != null;
}

/// Pure search across [files]. Synchronous; the typical payload
/// (a few thousand lines across N files) is fast enough to run on
/// every keystroke — callers still debounce for UI comfort.
///
/// Matches filenames in addition to content: a hit is emitted at
/// `line: 0, column: 0` with `lineContent = filename` so the user
/// sees the file surface even if no line inside it matches.
SearchResults searchFiles({
  required List<SearchableFile> files,
  required SearchOptions options,
}) {
  if (options.isEmpty) return SearchResults.empty;

  RegExp pattern;
  try {
    if (options.regex) {
      pattern = RegExp(options.query, caseSensitive: options.caseSensitive);
    } else {
      var pat = RegExp.escape(options.query);
      if (options.wholeWord) pat = r'\b' + pat + r'\b';
      pattern = RegExp(pat, caseSensitive: options.caseSensitive);
    }
  } catch (e) {
    return SearchResults(
      hits: const [],
      byFile: const {},
      fileCount: 0,
      totalHits: 0,
      regexError: e.toString(),
    );
  }

  final hits = <SearchHit>[];
  for (final file in files) {
    // Filename hit — emitted first for visibility, even if the file
    // has no in-content matches.
    if (pattern.hasMatch(file.filename)) {
      final match = pattern.firstMatch(file.filename)!;
      final length = match.end - match.start;
      if (length > 0) {
        hits.add(SearchHit(
          path: file.path,
          filename: file.filename,
          line: 0,
          column: match.start + 1,
          matchLength: length,
          lineContent: file.filename,
        ));
      }
    }
    final lines = file.content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (final match in pattern.allMatches(line)) {
        final length = match.end - match.start;
        if (length == 0) continue;
        hits.add(SearchHit(
          path: file.path,
          filename: file.filename,
          line: i + 1,
          column: match.start + 1,
          matchLength: length,
          lineContent: line,
        ));
      }
    }
  }

  final byFile = <String, List<SearchHit>>{};
  for (final h in hits) {
    byFile.putIfAbsent(h.path, () => []).add(h);
  }

  return SearchResults(
    hits: hits,
    byFile: byFile,
    fileCount: byFile.length,
    totalHits: hits.length,
  );
}

/// Back-compat wrapper — lets callers that only have buffer lists
/// keep working. New code should build [SearchableFile]s via
/// [collectSearchableFiles] and call [searchFiles] directly.
SearchResults searchBuffers({
  required List<WorkbenchBuffer> buffers,
  required SearchOptions options,
}) =>
    searchFiles(
      files: buffers.map(SearchableFile.fromBuffer).toList(),
      options: options,
    );
