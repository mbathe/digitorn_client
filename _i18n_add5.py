import json
ROOT = 'C:/Users/ASUS/Documents/digitorn_client/assets/translations/'
LANGS = ['en', 'fr', 'es', 'de', 'pt', 'it']

EDITOR = {
    'could_not_load_file': {
        'en': 'Could not load file content.', 'fr': "Impossible de charger le contenu du fichier.",
        'es': 'No se pudo cargar el contenido del archivo.', 'de': 'Dateiinhalt konnte nicht geladen werden.',
        'pt': 'Não foi possível carregar o conteúdo do arquivo.', 'it': 'Impossibile caricare il contenuto del file.'
    },
    'load_failed': {
        'en': 'Load failed: {error}', 'fr': 'Échec du chargement : {error}',
        'es': 'Error al cargar: {error}', 'de': 'Laden fehlgeschlagen: {error}',
        'pt': 'Falha ao carregar: {error}', 'it': 'Caricamento non riuscito: {error}'
    },
    'retry': {
        'en': 'Retry', 'fr': 'Réessayer', 'es': 'Reintentar',
        'de': 'Wiederholen', 'pt': 'Tentar novamente', 'it': 'Riprova'
    },
    'no_diff_available': {
        'en': 'No diff available — content matches the baseline.',
        'fr': 'Aucune différence — le contenu correspond à la base.',
        'es': 'No hay diferencias — el contenido coincide con la base.',
        'de': 'Kein Diff verfügbar — Inhalt entspricht der Basis.',
        'pt': 'Sem diff disponível — o conteúdo corresponde ao baseline.',
        'it': 'Nessuna differenza — il contenuto corrisponde alla base.'
    },
    'diff': {
        'en': 'Diff', 'fr': 'Diff', 'es': 'Diff',
        'de': 'Diff', 'pt': 'Diff', 'it': 'Diff'
    },
    'editing': {
        'en': 'Editing', 'fr': 'Édition', 'es': 'Editando',
        'de': 'Bearbeiten', 'pt': 'Editando', 'it': 'Modifica'
    },
    'edit': {
        'en': 'Edit', 'fr': 'Modifier', 'es': 'Editar',
        'de': 'Bearbeiten', 'pt': 'Editar', 'it': 'Modifica'
    },
    'conflicts': {
        'en': 'Conflicts', 'fr': 'Conflits', 'es': 'Conflictos',
        'de': 'Konflikte', 'pt': 'Conflitos', 'it': 'Conflitti'
    },
    'history_short': {
        'en': 'Hist', 'fr': 'Hist', 'es': 'Hist',
        'de': 'Verl.', 'pt': 'Hist', 'it': 'Cron.'
    },
    'reload': {
        'en': 'Reload', 'fr': 'Recharger', 'es': 'Recargar',
        'de': 'Neu laden', 'pt': 'Recarregar', 'it': 'Ricarica'
    },
    'approve_file': {
        'en': 'Approve file', 'fr': 'Approuver le fichier', 'es': 'Aprobar archivo',
        'de': 'Datei genehmigen', 'pt': 'Aprovar arquivo', 'it': 'Approva file'
    },
    'reject_to_baseline': {
        'en': 'Reject — revert to baseline', 'fr': 'Rejeter — revenir à la base',
        'es': 'Rechazar — volver a la base', 'de': 'Ablehnen — auf Basis zurücksetzen',
        'pt': 'Rejeitar — reverter ao baseline', 'it': 'Rifiuta — ripristina la base'
    },
    'stage_hunk': {
        'en': 'Stage this hunk', 'fr': "Mettre ce bloc en index",
        'es': 'Añadir este bloque al índice', 'de': 'Diesen Block stagen',
        'pt': 'Marcar este bloco', 'it': 'Aggiungi questo blocco all’indice'
    },
    'revert_hunk': {
        'en': 'Revert this hunk', 'fr': 'Annuler ce bloc',
        'es': 'Revertir este bloque', 'de': 'Diesen Block zurücksetzen',
        'pt': 'Reverter este bloco', 'it': 'Annulla questo blocco'
    },
    'file_still_loading': {
        'en': 'File still loading', 'fr': 'Fichier en cours de chargement',
        'es': 'El archivo aún se está cargando', 'de': 'Datei wird noch geladen',
        'pt': 'Arquivo ainda carregando', 'it': 'File ancora in caricamento'
    },
    'copy_content_right_click': {
        'en': 'Copy content (right-click → copy path)',
        'fr': 'Copier le contenu (clic droit → copier le chemin)',
        'es': 'Copiar contenido (clic derecho → copiar ruta)',
        'de': 'Inhalt kopieren (Rechtsklick → Pfad kopieren)',
        'pt': 'Copiar conteúdo (clique direito → copiar caminho)',
        'it': 'Copia contenuto (clic destro → copia percorso)'
    },
    'download_file': {
        'en': 'Download file', 'fr': 'Télécharger le fichier',
        'es': 'Descargar archivo', 'de': 'Datei herunterladen',
        'pt': 'Baixar arquivo', 'it': 'Scarica file'
    },
    'saved_to': {
        'en': 'Saved to {path}', 'fr': 'Enregistré dans {path}',
        'es': 'Guardado en {path}', 'de': 'Gespeichert in {path}',
        'pt': 'Salvo em {path}', 'it': 'Salvato in {path}'
    },
    'download_failed': {
        'en': 'Download failed: {error}', 'fr': 'Échec du téléchargement : {error}',
        'es': 'Descarga fallida: {error}', 'de': 'Download fehlgeschlagen: {error}',
        'pt': 'Falha no download: {error}', 'it': 'Download non riuscito: {error}'
    },
    'attach_failed': {
        'en': 'Could not attach to chat: {error}',
        'fr': 'Impossible de joindre au chat : {error}',
        'es': 'No se pudo adjuntar al chat: {error}',
        'de': 'Konnte nicht an Chat anhängen: {error}',
        'pt': 'Não foi possível anexar ao chat: {error}',
        'it': 'Impossibile allegare alla chat: {error}'
    },
    'add_to_chat_context': {
        'en': 'Add file to chat context', 'fr': 'Ajouter le fichier au contexte du chat',
        'es': 'Añadir archivo al contexto del chat', 'de': 'Datei zum Chat-Kontext hinzufügen',
        'pt': 'Adicionar arquivo ao contexto do chat', 'it': 'Aggiungi file al contesto della chat'
    },
    'hunks_count_single': {
        'en': '{n} hunk', 'fr': '{n} bloc', 'es': '{n} bloque',
        'de': '{n} Block', 'pt': '{n} bloco', 'it': '{n} blocco'
    },
    'hunks_count_plural': {
        'en': '{n} hunks', 'fr': '{n} blocs', 'es': '{n} bloques',
        'de': '{n} Blöcke', 'pt': '{n} blocos', 'it': '{n} blocchi'
    },
}

for lang in LANGS:
    path = ROOT + lang + '.json'
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    ns = data.setdefault('editor', {})
    for key, tr in EDITOR.items():
        ns[key] = tr[lang]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
print('done')
