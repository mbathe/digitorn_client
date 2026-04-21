import json
ROOT = 'C:/Users/ASUS/Documents/digitorn_client/assets/translations/'
LANGS = ['en', 'fr', 'es', 'de', 'pt', 'it']

VIEWERS = {
    'pdf_search_ctrl_f': {
        'en': 'Search (Ctrl+F)', 'fr': 'Rechercher (Ctrl+F)', 'es': 'Buscar (Ctrl+F)',
        'de': 'Suchen (Strg+F)', 'pt': 'Pesquisar (Ctrl+F)', 'it': 'Cerca (Ctrl+F)'
    },
    'pdf_search_in': {
        'en': 'Search in PDF…', 'fr': 'Rechercher dans le PDF…', 'es': 'Buscar en PDF…',
        'de': 'In PDF suchen…', 'pt': 'Pesquisar no PDF…', 'it': 'Cerca nel PDF…'
    },
    'pdf_no_matches': {
        'en': 'No matches', 'fr': 'Aucun résultat', 'es': 'Sin coincidencias',
        'de': 'Keine Treffer', 'pt': 'Sem resultados', 'it': 'Nessun risultato'
    },
    'pdf_previous': {
        'en': 'Previous', 'fr': 'Précédent', 'es': 'Anterior',
        'de': 'Zurück', 'pt': 'Anterior', 'it': 'Precedente'
    },
    'pdf_next': {
        'en': 'Next', 'fr': 'Suivant', 'es': 'Siguiente',
        'de': 'Weiter', 'pt': 'Próximo', 'it': 'Successivo'
    },
    'pdf_close_search': {
        'en': 'Close search', 'fr': 'Fermer la recherche', 'es': 'Cerrar búsqueda',
        'de': 'Suche schließen', 'pt': 'Fechar pesquisa', 'it': 'Chiudi ricerca'
    },
    'pdf_first_page': {
        'en': 'First page', 'fr': 'Première page', 'es': 'Primera página',
        'de': 'Erste Seite', 'pt': 'Primeira página', 'it': 'Prima pagina'
    },
    'pdf_previous_page': {
        'en': 'Previous page', 'fr': 'Page précédente', 'es': 'Página anterior',
        'de': 'Vorherige Seite', 'pt': 'Página anterior', 'it': 'Pagina precedente'
    },
    'pdf_next_page': {
        'en': 'Next page', 'fr': 'Page suivante', 'es': 'Página siguiente',
        'de': 'Nächste Seite', 'pt': 'Próxima página', 'it': 'Pagina successiva'
    },
    'pdf_last_page': {
        'en': 'Last page', 'fr': 'Dernière page', 'es': 'Última página',
        'de': 'Letzte Seite', 'pt': 'Última página', 'it': 'Ultima pagina'
    },
    'pdf_pages_count': {
        'en': '{n} pages', 'fr': '{n} pages', 'es': '{n} páginas',
        'de': '{n} Seiten', 'pt': '{n} páginas', 'it': '{n} pagine'
    },
    'pdf_reset_zoom': {
        'en': 'Reset zoom', 'fr': 'Réinitialiser le zoom', 'es': 'Restablecer zoom',
        'de': 'Zoom zurücksetzen', 'pt': 'Redefinir zoom', 'it': 'Ripristina zoom'
    },
    'pdf_cannot_load': {
        'en': 'Cannot load PDF', 'fr': 'Impossible de charger le PDF', 'es': 'No se puede cargar el PDF',
        'de': 'PDF kann nicht geladen werden', 'pt': 'Não é possível carregar o PDF', 'it': 'Impossibile caricare il PDF'
    },
    # Editor pane
    'editor_problems': {
        'en': 'Problems', 'fr': 'Problèmes', 'es': 'Problemas',
        'de': 'Probleme', 'pt': 'Problemas', 'it': 'Problemi'
    },
    'editor_minimap': {
        'en': 'Toggle minimap', 'fr': 'Afficher/masquer la mini-carte', 'es': 'Alternar minimapa',
        'de': 'Mini-Karte umschalten', 'pt': 'Alternar minimapa', 'it': 'Attiva/disattiva minimappa'
    },
    'editor_wrap': {
        'en': 'Toggle word wrap', 'fr': 'Retour à la ligne automatique', 'es': 'Alternar ajuste de línea',
        'de': 'Zeilenumbruch umschalten', 'pt': 'Alternar quebra de linha', 'it': 'Attiva/disattiva a capo automatico'
    },
    'editor_line_col': {
        'en': 'Ln {line}, Col {col}', 'fr': 'Ligne {line}, Col {col}', 'es': 'Ln {line}, Col {col}',
        'de': 'Zeile {line}, Sp {col}', 'pt': 'Lin {line}, Col {col}', 'it': 'Riga {line}, Col {col}'
    },
    'editor_encoding': {
        'en': 'Encoding', 'fr': 'Encodage', 'es': 'Codificación',
        'de': 'Kodierung', 'pt': 'Codificação', 'it': 'Codifica'
    },
    'editor_eol': {
        'en': 'EOL', 'fr': 'Fin de ligne', 'es': 'EOL',
        'de': 'Zeilenende', 'pt': 'EOL', 'it': 'EOL'
    },
    'editor_indent': {
        'en': 'Indent', 'fr': 'Indentation', 'es': 'Sangría',
        'de': 'Einzug', 'pt': 'Indentação', 'it': 'Rientro'
    },
    # Structured data viewer
    'structured_cell_copy': {
        'en': 'Copy cell', 'fr': 'Copier la cellule', 'es': 'Copiar celda',
        'de': 'Zelle kopieren', 'pt': 'Copiar célula', 'it': 'Copia cella'
    },
    'structured_row_copy': {
        'en': 'Copy row', 'fr': 'Copier la ligne', 'es': 'Copiar fila',
        'de': 'Zeile kopieren', 'pt': 'Copiar linha', 'it': 'Copia riga'
    },
    'structured_error': {
        'en': 'Failed to parse', 'fr': 'Échec de l’analyse', 'es': 'Error al analizar',
        'de': 'Analyse fehlgeschlagen', 'pt': 'Falha ao analisar', 'it': 'Analisi non riuscita'
    },
    'structured_filter': {
        'en': 'Filter…', 'fr': 'Filtrer…', 'es': 'Filtrar…',
        'de': 'Filtern…', 'pt': 'Filtrar…', 'it': 'Filtra…'
    },
    'structured_loading': {
        'en': 'Loading…', 'fr': 'Chargement…', 'es': 'Cargando…',
        'de': 'Lädt…', 'pt': 'Carregando…', 'it': 'Caricamento…'
    },
    'structured_header_row': {
        'en': 'Treat first row as header',
        'fr': 'Traiter la première ligne comme en-tête',
        'es': 'Tratar la primera fila como encabezado',
        'de': 'Erste Zeile als Kopfzeile behandeln',
        'pt': 'Tratar a primeira linha como cabeçalho',
        'it': 'Tratta la prima riga come intestazione'
    },
    'csv_delimiter': {
        'en': 'Delimiter', 'fr': 'Séparateur', 'es': 'Delimitador',
        'de': 'Trennzeichen', 'pt': 'Delimitador', 'it': 'Delimitatore'
    },
    'csv_rows_cols': {
        'en': '{rows} rows · {cols} cols', 'fr': '{rows} lignes · {cols} colonnes',
        'es': '{rows} filas · {cols} cols', 'de': '{rows} Zeilen · {cols} Spalten',
        'pt': '{rows} linhas · {cols} cols', 'it': '{rows} righe · {cols} colonne'
    },
    'notebook_cells': {
        'en': '{n} cells', 'fr': '{n} cellules', 'es': '{n} celdas',
        'de': '{n} Zellen', 'pt': '{n} células', 'it': '{n} celle'
    },
    'notebook_markdown': {
        'en': 'Markdown', 'fr': 'Markdown', 'es': 'Markdown',
        'de': 'Markdown', 'pt': 'Markdown', 'it': 'Markdown'
    },
    'notebook_code': {
        'en': 'Code', 'fr': 'Code', 'es': 'Código',
        'de': 'Code', 'pt': 'Código', 'it': 'Codice'
    },
    'notebook_output': {
        'en': 'Output', 'fr': 'Sortie', 'es': 'Salida',
        'de': 'Ausgabe', 'pt': 'Saída', 'it': 'Output'
    },
    'notebook_no_cells': {
        'en': 'No cells in this notebook', 'fr': 'Aucune cellule dans ce notebook',
        'es': 'No hay celdas en este cuaderno', 'de': 'Keine Zellen in diesem Notebook',
        'pt': 'Sem células neste notebook', 'it': 'Nessuna cella in questo notebook'
    },
    'image_fit': {
        'en': 'Fit', 'fr': 'Adapter', 'es': 'Ajustar',
        'de': 'Anpassen', 'pt': 'Ajustar', 'it': 'Adatta'
    },
    'image_actual': {
        'en': 'Actual size', 'fr': 'Taille réelle', 'es': 'Tamaño real',
        'de': 'Originalgröße', 'pt': 'Tamanho real', 'it': 'Dimensione reale'
    },
    'markdown_source': {
        'en': 'Source', 'fr': 'Source', 'es': 'Fuente',
        'de': 'Quelltext', 'pt': 'Fonte', 'it': 'Sorgente'
    },
    'log_tail_follow': {
        'en': 'Follow tail', 'fr': 'Suivre la fin', 'es': 'Seguir cola',
        'de': 'Tail folgen', 'pt': 'Seguir final', 'it': 'Segui coda'
    },
    'preview_reload_btn': {
        'en': 'Reload preview', 'fr': "Recharger l'aperçu", 'es': 'Recargar vista previa',
        'de': 'Vorschau neu laden', 'pt': 'Recarregar visualização', 'it': "Ricarica anteprima"
    },
    'preview_open_browser_btn': {
        'en': 'Open in browser', 'fr': 'Ouvrir dans le navigateur', 'es': 'Abrir en el navegador',
        'de': 'Im Browser öffnen', 'pt': 'Abrir no navegador', 'it': 'Apri nel browser'
    },
    'preview_no_preview': {
        'en': 'No preview available', 'fr': 'Aucun aperçu disponible',
        'es': 'Vista previa no disponible', 'de': 'Keine Vorschau verfügbar',
        'pt': 'Visualização indisponível', 'it': 'Anteprima non disponibile'
    },
    'preview_title': {
        'en': 'Preview', 'fr': 'Aperçu', 'es': 'Vista previa',
        'de': 'Vorschau', 'pt': 'Visualização', 'it': 'Anteprima'
    },
}

for lang in LANGS:
    path = ROOT + lang + '.json'
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    ns = data.setdefault('viewers', {})
    for key, tr in VIEWERS.items():
        ns[key] = tr[lang]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
print('done')
