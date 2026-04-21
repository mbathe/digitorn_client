import 'dart:io' as io;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../../../services/auth_service.dart';
import '../../../services/session_service.dart';
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';

/// Full-featured PDF viewer powered by Syncfusion. Supports text selection,
/// search, multi-page navigation, zoom, and matches the app theme via a
/// custom themed toolbar (the built-in Syncfusion toolbar is intentionally
/// disabled to keep visual consistency).
///
/// Source resolution:
/// - On desktop the file lives on the same machine as the daemon, so we
///   stream it directly via [SfPdfViewer.file].
/// - On web we hit the daemon's raw-file endpoint
///   `GET /api/apps/{appId}/sessions/{sid}/workbench/raw?path=…` and let
///   Syncfusion fetch over HTTP via [SfPdfViewer.network]. If the daemon
///   does not yet expose this endpoint, the viewer surfaces a clear error
///   state via [SfPdfViewer.onDocumentLoadFailed].
class PdfFileViewer extends FileViewer with NavigableViewer, SearchableViewer {
  const PdfFileViewer();

  @override
  String get id => 'pdf';

  @override
  int get priority => 100;

  @override
  Set<String> get extensions => const {'pdf'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    return _PdfPane(
      key: ValueKey('pdf-${vctx.buffer.path}'),
      buffer: vctx.buffer,
    );
  }
}

class _PdfPane extends StatefulWidget {
  final dynamic buffer; // WorkbenchBuffer (kept dynamic to avoid circular imports here)
  const _PdfPane({super.key, required this.buffer});

  @override
  State<_PdfPane> createState() => _PdfPaneState();
}

class _PdfPaneState extends State<_PdfPane> {
  late final PdfViewerController _ctrl;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  bool _searching = false;
  PdfTextSearchResult? _searchResult;

  int _currentPage = 1;
  int _pageCount = 0;
  String? _loadError;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _ctrl = PdfViewerController();
  }

  @override
  void dispose() {
    _searchResult?.removeListener(_onSearchChanged);
    _searchResult?.clear();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // ── Zoom helpers ──────────────────────────────────────────────────────

  static const double _minZoom = 0.5;
  static const double _maxZoom = 5.0;
  static const double _zoomStep = 0.25;

  void _zoomIn() {
    setState(() {
      _ctrl.zoomLevel = (_ctrl.zoomLevel + _zoomStep).clamp(_minZoom, _maxZoom);
    });
  }

  void _zoomOut() {
    setState(() {
      _ctrl.zoomLevel = (_ctrl.zoomLevel - _zoomStep).clamp(_minZoom, _maxZoom);
    });
  }

  void _zoomReset() {
    setState(() {
      _ctrl.zoomLevel = 1.0;
    });
  }

  // ── Page navigation ───────────────────────────────────────────────────

  void _firstPage() {
    if (_pageCount == 0) return;
    _ctrl.jumpToPage(1);
  }

  void _previousPage() {
    if (_currentPage > 1) _ctrl.previousPage();
  }

  void _nextPage() {
    if (_currentPage < _pageCount) _ctrl.nextPage();
  }

  void _lastPage() {
    if (_pageCount == 0) return;
    _ctrl.jumpToPage(_pageCount);
  }

  // ── Search ────────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (_searching) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _searchFocus.requestFocus(),
        );
      } else {
        _searchResult?.removeListener(_onSearchChanged);
        _searchResult?.clear();
        _searchResult = null;
        _searchCtrl.clear();
      }
    });
  }

  void _runSearch(String q) {
    final query = q.trim();
    if (query.isEmpty) {
      _searchResult?.removeListener(_onSearchChanged);
      _searchResult?.clear();
      setState(() => _searchResult = null);
      return;
    }
    _searchResult?.removeListener(_onSearchChanged);
    _searchResult?.clear();
    final result = _ctrl.searchText(query);
    result.addListener(_onSearchChanged);
    setState(() => _searchResult = result);
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  void _searchNext() => _searchResult?.nextInstance();
  void _searchPrev() => _searchResult?.previousInstance();

  // ── Source URL (web only) ─────────────────────────────────────────────

  String _networkUrl() {
    final base = AuthService().baseUrl;
    final session = SessionService().activeSession;
    final appId = session?.appId ?? '';
    final sid = session?.sessionId ?? '';
    final path = Uri.encodeQueryComponent(widget.buffer.path as String);
    return '$base/api/apps/$appId/sessions/$sid/workbench/raw?path=$path';
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final filename = widget.buffer.filename as String;

    return Container(
      color: c.bg,
      child: Column(
        children: [
          _buildHeader(c, filename),
          Container(height: 1, color: c.border),
          Expanded(child: _buildBody(c)),
          _buildStatusBar(c),
        ],
      ),
    );
  }

  Widget _buildHeader(AppColors c, String filename) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.surface,
      child: _searching
          ? _buildSearchBar(c)
          : Row(
              children: [
                Icon(Icons.picture_as_pdf_rounded, size: 15, color: c.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    filename,
                    style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _PdfBadge(label: 'PDF', color: c.red),
                const SizedBox(width: 12),
                _PdfIconBtn(
                  icon: Icons.search_rounded,
                  tooltip: 'viewers.pdf_search_ctrl_f'.tr(),
                  enabled: _loaded,
                  onTap: _toggleSearch,
                ),
                const SizedBox(width: 4),
                _PdfIconBtn(
                  icon: Icons.zoom_out_rounded,
                  tooltip: 'viewers.pdf_zoom_out'.tr(),
                  enabled: _loaded,
                  onTap: _zoomOut,
                ),
                _PdfZoomLabel(zoom: _ctrl.zoomLevel, enabled: _loaded, onTap: _zoomReset),
                _PdfIconBtn(
                  icon: Icons.zoom_in_rounded,
                  tooltip: 'viewers.pdf_zoom_in'.tr(),
                  enabled: _loaded,
                  onTap: _zoomIn,
                ),
              ],
            ),
    );
  }

  Widget _buildSearchBar(AppColors c) {
    final result = _searchResult;
    final hasResults = result != null && result.totalInstanceCount > 0;
    return Row(
      children: [
        Icon(Icons.search_rounded, size: 14, color: c.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            onSubmitted: _runSearch,
            onChanged: (v) {
              if (v.isEmpty) _runSearch('');
            },
            style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'viewers.pdf_search_in'.tr(),
              hintStyle: GoogleFonts.firaCode(
                fontSize: 12, color: c.textMuted,
              ),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        if (result != null) ...[
          Text(
            hasResults
                ? '${result.currentInstanceIndex} / ${result.totalInstanceCount}'
                : 'viewers.pdf_no_matches'.tr(),
            style: GoogleFonts.firaCode(
                fontSize: 11,
                color: hasResults ? c.text : c.textMuted),
          ),
          const SizedBox(width: 6),
          _PdfIconBtn(
            icon: Icons.keyboard_arrow_up_rounded,
            tooltip: 'viewers.pdf_previous'.tr(),
            enabled: hasResults,
            onTap: _searchPrev,
          ),
          _PdfIconBtn(
            icon: Icons.keyboard_arrow_down_rounded,
            tooltip: 'viewers.pdf_next'.tr(),
            enabled: hasResults,
            onTap: _searchNext,
          ),
        ],
        const SizedBox(width: 6),
        _PdfIconBtn(
          icon: Icons.close_rounded,
          tooltip: 'viewers.pdf_close_search'.tr(),
          enabled: true,
          onTap: _toggleSearch,
        ),
      ],
    );
  }

  Widget _buildBody(AppColors c) {
    if (_loadError != null) {
      return _PdfErrorState(error: _loadError!);
    }

    final viewer = kIsWeb
        ? SfPdfViewer.network(
            _networkUrl(),
            controller: _ctrl,
            canShowScrollHead: false,
            canShowScrollStatus: false,
            canShowPaginationDialog: false,
            enableTextSelection: true,
            onDocumentLoaded: _onLoaded,
            onPageChanged: _onPageChanged,
            onDocumentLoadFailed: _onLoadFailed,
          )
        : SfPdfViewer.file(
            io.File(widget.buffer.path as String),
            controller: _ctrl,
            canShowScrollHead: false,
            canShowScrollStatus: false,
            canShowPaginationDialog: false,
            enableTextSelection: true,
            onDocumentLoaded: _onLoaded,
            onPageChanged: _onPageChanged,
            onDocumentLoadFailed: _onLoadFailed,
          );

    // Wrap in a Theme override so the Syncfusion viewer adopts our colors
    // for backgrounds and the (hidden) overlays.
    return Theme(
      data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: c.bg,
        canvasColor: c.bg,
      ),
      child: viewer,
    );
  }

  Widget _buildStatusBar(AppColors c) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          _PdfNavBtn(
            icon: Icons.first_page_rounded,
            tooltip: 'viewers.pdf_first_page'.tr(),
            enabled: _loaded && _currentPage > 1,
            onTap: _firstPage,
          ),
          _PdfNavBtn(
            icon: Icons.chevron_left_rounded,
            tooltip: 'viewers.pdf_previous_page'.tr(),
            enabled: _loaded && _currentPage > 1,
            onTap: _previousPage,
          ),
          const SizedBox(width: 6),
          Text(
            _loaded ? '$_currentPage / $_pageCount' : '— / —',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
          const SizedBox(width: 6),
          _PdfNavBtn(
            icon: Icons.chevron_right_rounded,
            tooltip: 'viewers.pdf_next_page'.tr(),
            enabled: _loaded && _currentPage < _pageCount,
            onTap: _nextPage,
          ),
          _PdfNavBtn(
            icon: Icons.last_page_rounded,
            tooltip: 'viewers.pdf_last_page'.tr(),
            enabled: _loaded && _currentPage < _pageCount,
            onTap: _lastPage,
          ),
          const Spacer(),
          if (_loaded) ...[
            Text('viewers.pdf_pages_count'.tr(namedArgs: {'n': '$_pageCount'}),
                style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
            const SizedBox(width: 12),
          ],
          Text('PDF',
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
        ],
      ),
    );
  }

  // ── Syncfusion callbacks ──────────────────────────────────────────────

  void _onLoaded(PdfDocumentLoadedDetails details) {
    if (!mounted) return;
    setState(() {
      _pageCount = details.document.pages.count;
      _currentPage = 1;
      _loaded = true;
      _loadError = null;
    });
  }

  void _onPageChanged(PdfPageChangedDetails details) {
    if (!mounted) return;
    setState(() => _currentPage = details.newPageNumber);
  }

  void _onLoadFailed(PdfDocumentLoadFailedDetails details) {
    if (!mounted) return;
    setState(() {
      _loadError = '${details.error}\n${details.description}';
      _loaded = false;
    });
  }
}

// ─── Tiny themed widgets used inside the viewer ────────────────────────────

class _PdfBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _PdfBadge({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
          style: GoogleFonts.firaCode(
              fontSize: 9, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _PdfIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  const _PdfIconBtn({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });
  @override
  State<_PdfIconBtn> createState() => _PdfIconBtnState();
}

class _PdfIconBtnState extends State<_PdfIconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = widget.enabled
        ? (_h ? c.text : c.textMuted)
        : c.textDim;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _h && widget.enabled
                  ? c.surfaceAlt
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(widget.icon, size: 14, color: color),
          ),
        ),
      ),
    );
  }
}

class _PdfNavBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  const _PdfNavBtn({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });
  @override
  State<_PdfNavBtn> createState() => _PdfNavBtnState();
}

class _PdfNavBtnState extends State<_PdfNavBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = widget.enabled
        ? (_h ? c.text : c.textMuted)
        : c.textDim;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: SizedBox(
            width: 20,
            height: 20,
            child: Icon(widget.icon, size: 13, color: color),
          ),
        ),
      ),
    );
  }
}

class _PdfZoomLabel extends StatefulWidget {
  final double zoom;
  final bool enabled;
  final VoidCallback onTap;
  const _PdfZoomLabel({
    required this.zoom,
    required this.enabled,
    required this.onTap,
  });
  @override
  State<_PdfZoomLabel> createState() => _PdfZoomLabelState();
}

class _PdfZoomLabelState extends State<_PdfZoomLabel> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final percent = '${(widget.zoom * 100).round()}%';
    return Tooltip(
      message: 'viewers.pdf_reset_zoom'.tr(),
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 44,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _h && widget.enabled
                  ? c.surfaceAlt
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(percent,
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: widget.enabled ? c.text : c.textDim)),
          ),
        ),
      ),
    );
  }
}

class _PdfErrorState extends StatelessWidget {
  final String error;
  const _PdfErrorState({required this.error});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text('viewers.pdf_cannot_load'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      color: c.text,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                error,
                textAlign: TextAlign.center,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
