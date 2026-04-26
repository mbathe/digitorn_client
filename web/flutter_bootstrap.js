{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // Use the HTML renderer instead of CanvasKit.
    // CanvasKit ships a 2MB Wasm binary and repaints the entire canvas on
    // every frame — expensive for a chat UI with constant token streaming.
    // The HTML renderer uses CSS / DOM and is significantly faster for
    // text-heavy, frequently-updated content.
    renderer: "html",
  },
});
