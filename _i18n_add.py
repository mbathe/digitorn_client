"""Add i18n keys across 6 language JSONs."""
import json, os, sys

ROOT = 'C:/Users/ASUS/Documents/digitorn_client/assets/translations/'
LANGS = ['en', 'fr', 'es', 'de', 'pt', 'it']

# namespace -> key -> {lang: value}
ADDITIONS = {}


def add(ns, key, translations):
    ADDITIONS.setdefault(ns, {})[key] = translations


# ── chat_panel.dart ────────────────────────────────────────────────
add('chat', 'daemon_offline_reconnecting', {
    'en': 'Daemon offline — reconnecting…',
    'fr': 'Daemon hors ligne — reconnexion…',
    'es': 'Daemon sin conexión — reconectando…',
    'de': 'Daemon offline — Neuverbindung…',
    'pt': 'Daemon offline — reconectando…',
    'it': 'Daemon offline — riconnessione…',
})
add('chat', 'select_short', {
    'en': 'Select',
    'fr': 'Sélectionner',
    'es': 'Seleccionar',
    'de': 'Auswählen',
    'pt': 'Selecionar',
    'it': 'Seleziona',
})
add('chat', 'allow', {
    'en': 'Allow',
    'fr': 'Autoriser',
    'es': 'Permitir',
    'de': 'Erlauben',
    'pt': 'Permitir',
    'it': 'Consenti',
})
add('chat', 'deny', {
    'en': 'Deny',
    'fr': 'Refuser',
    'es': 'Denegar',
    'de': 'Ablehnen',
    'pt': 'Negar',
    'it': 'Nega',
})
add('chat', 'type_response_hint', {
    'en': 'Type your response...',
    'fr': 'Tapez votre réponse...',
    'es': 'Escribe tu respuesta...',
    'de': 'Antwort eingeben...',
    'pt': 'Digite sua resposta...',
    'it': 'Digita la tua risposta...',
})
add('chat', 'respond', {
    'en': 'Respond',
    'fr': 'Répondre',
    'es': 'Responder',
    'de': 'Antworten',
    'pt': 'Responder',
    'it': 'Rispondi',
})
add('chat', 'skip', {
    'en': 'Skip',
    'fr': 'Ignorer',
    'es': 'Omitir',
    'de': 'Überspringen',
    'pt': 'Ignorar',
    'it': 'Salta',
})
add('chat', 'confirm_count', {
    'en': 'Confirm ({n})',
    'fr': 'Confirmer ({n})',
    'es': 'Confirmar ({n})',
    'de': 'Bestätigen ({n})',
    'pt': 'Confirmar ({n})',
    'it': 'Conferma ({n})',
})
add('chat', 'feedback_optional_hint', {
    'en': 'Feedback (optional)...',
    'fr': 'Commentaire (facultatif)...',
    'es': 'Comentario (opcional)...',
    'de': 'Feedback (optional)...',
    'pt': 'Feedback (opcional)...',
    'it': 'Feedback (facoltativo)...',
})
add('chat', 'approve', {
    'en': 'Approve',
    'fr': 'Approuver',
    'es': 'Aprobar',
    'de': 'Genehmigen',
    'pt': 'Aprovar',
    'it': 'Approva',
})
add('chat', 'reject', {
    'en': 'Reject',
    'fr': 'Rejeter',
    'es': 'Rechazar',
    'de': 'Ablehnen',
    'pt': 'Rejeitar',
    'it': 'Rifiuta',
})
add('chat', 'submit', {
    'en': 'Submit',
    'fr': 'Envoyer',
    'es': 'Enviar',
    'de': 'Absenden',
    'pt': 'Enviar',
    'it': 'Invia',
})
add('chat', 'cancel', {
    'en': 'Cancel',
    'fr': 'Annuler',
    'es': 'Cancelar',
    'de': 'Abbrechen',
    'pt': 'Cancelar',
    'it': 'Annulla',
})
add('chat', 'required_field', {
    'en': 'Required',
    'fr': 'Obligatoire',
    'es': 'Obligatorio',
    'de': 'Pflichtfeld',
    'pt': 'Obrigatório',
    'it': 'Obbligatorio',
})
add('chat', 'select_hint', {
    'en': 'Select...',
    'fr': 'Sélectionner...',
    'es': 'Seleccionar...',
    'de': 'Auswählen...',
    'pt': 'Selecionar...',
    'it': 'Seleziona...',
})
add('chat', 'reason_optional_hint', {
    'en': 'Reason (optional)...',
    'fr': 'Raison (facultative)...',
    'es': 'Motivo (opcional)...',
    'de': 'Grund (optional)...',
    'pt': 'Motivo (opcional)...',
    'it': 'Motivo (facoltativo)...',
})
add('chat', 'send_short', {
    'en': 'Send',
    'fr': 'Envoyer',
    'es': 'Enviar',
    'de': 'Senden',
    'pt': 'Enviar',
    'it': 'Invia',
})
add('chat', 'agent_has_question', {
    'en': 'Agent has a question',
    'fr': "L'agent a une question",
    'es': 'El agente tiene una pregunta',
    'de': 'Der Agent hat eine Frage',
    'pt': 'O agente tem uma pergunta',
    'it': "L'agente ha una domanda",
})
add('chat', 'view_in_panel', {
    'en': 'View in panel \u2192',
    'fr': 'Voir dans le panneau \u2192',
    'es': 'Ver en panel \u2192',
    'de': 'Im Panel anzeigen \u2192',
    'pt': 'Ver no painel \u2192',
    'it': 'Vedi nel pannello \u2192',
})
add('chat', 'copy_short', {
    'en': 'Copy',
    'fr': 'Copier',
    'es': 'Copiar',
    'de': 'Kopieren',
    'pt': 'Copiar',
    'it': 'Copia',
})
add('chat', 'copied_short', {
    'en': 'Copied',
    'fr': 'Copié',
    'es': 'Copiado',
    'de': 'Kopiert',
    'pt': 'Copiado',
    'it': 'Copiato',
})
add('chat', 'image_pasted_clipboard', {
    'en': 'Image pasted from clipboard',
    'fr': 'Image collée depuis le presse-papiers',
    'es': 'Imagen pegada desde el portapapeles',
    'de': 'Bild aus der Zwischenablage eingefügt',
    'pt': 'Imagem colada da área de transferência',
    'it': 'Immagine incollata dagli appunti',
})
add('chat', 'tools_short', {
    'en': 'Tools',
    'fr': 'Outils',
    'es': 'Herramientas',
    'de': 'Werkzeuge',
    'pt': 'Ferramentas',
    'it': 'Strumenti',
})
add('chat', 'snippets_short', {
    'en': 'Snippets',
    'fr': 'Extraits',
    'es': 'Fragmentos',
    'de': 'Snippets',
    'pt': 'Snippets',
    'it': 'Frammenti',
})
add('chat', 'background_tasks', {
    'en': 'Background tasks',
    'fr': 'Tâches en arrière-plan',
    'es': 'Tareas en segundo plano',
    'de': 'Hintergrundaufgaben',
    'pt': 'Tarefas em segundo plano',
    'it': 'Attività in background',
})
add('chat', 'background_tasks_running', {
    'en': 'Background tasks · {n} running',
    'fr': 'Tâches en arrière-plan · {n} en cours',
    'es': 'Tareas en segundo plano · {n} en curso',
    'de': 'Hintergrundaufgaben · {n} aktiv',
    'pt': 'Tarefas em segundo plano · {n} em execução',
    'it': 'Attività in background · {n} in corso',
})
add('chat', 'scroll_to_bottom', {
    'en': 'Scroll to bottom',
    'fr': 'Défiler vers le bas',
    'es': 'Ir al final',
    'de': 'Nach unten scrollen',
    'pt': 'Rolar até o fim',
    'it': 'Scorri in fondo',
})
add('chat', 'voice_stop_dictation', {
    'en': 'Stop dictation',
    'fr': 'Arrêter la dictée',
    'es': 'Detener dictado',
    'de': 'Diktat stoppen',
    'pt': 'Parar ditado',
    'it': 'Interrompi dettatura',
})
add('chat', 'voice_stop_recording', {
    'en': 'Stop recording',
    'fr': "Arrêter l'enregistrement",
    'es': 'Detener grabación',
    'de': 'Aufnahme stoppen',
    'pt': 'Parar gravação',
    'it': 'Interrompi registrazione',
})
add('chat', 'voice_unsupported', {
    'en': 'Voice input not supported here',
    'fr': 'Entrée vocale non prise en charge ici',
    'es': 'Entrada de voz no compatible aquí',
    'de': 'Spracheingabe hier nicht unterstützt',
    'pt': 'Entrada de voz não suportada aqui',
    'it': 'Input vocale non supportato qui',
})
add('chat', 'voice_dictate', {
    'en': 'Dictate a message',
    'fr': 'Dicter un message',
    'es': 'Dictar un mensaje',
    'de': 'Nachricht diktieren',
    'pt': 'Ditar uma mensagem',
    'it': 'Detta un messaggio',
})
add('chat', 'voice_dictate_server', {
    'en': 'Dictate (via server)',
    'fr': 'Dicter (via le serveur)',
    'es': 'Dictar (vía servidor)',
    'de': 'Diktieren (über Server)',
    'pt': 'Ditar (via servidor)',
    'it': 'Detta (via server)',
})
add('chat', 'voice_record_audio', {
    'en': 'Record audio message',
    'fr': 'Enregistrer un message audio',
    'es': 'Grabar mensaje de audio',
    'de': 'Audionachricht aufnehmen',
    'pt': 'Gravar mensagem de áudio',
    'it': 'Registra messaggio audio',
})
add('chat', 'voice_transcribing', {
    'en': 'Transcribing…',
    'fr': 'Transcription…',
    'es': 'Transcribiendo…',
    'de': 'Transkribiere…',
    'pt': 'Transcrevendo…',
    'it': 'Trascrizione…',
})
add('chat', 'voice_processing', {
    'en': 'Processing…',
    'fr': 'Traitement…',
    'es': 'Procesando…',
    'de': 'Verarbeite…',
    'pt': 'Processando…',
    'it': 'Elaborazione…',
})
add('chat', 'abort_current_turn', {
    'en': 'Abort current turn · {n} queued',
    'fr': "Interrompre le tour actuel · {n} en file d'attente",
    'es': 'Abortar turno actual · {n} en cola',
    'de': 'Aktuellen Turn abbrechen · {n} in Warteschlange',
    'pt': 'Abortar turno atual · {n} na fila',
    'it': 'Interrompi turno corrente · {n} in coda',
})
add('chat', 'send_will_queue', {
    'en': 'Send (will queue after the current turn)',
    'fr': 'Envoyer (mis en file après le tour actuel)',
    'es': 'Enviar (se pondrá en cola tras el turno actual)',
    'de': 'Senden (wird nach aktuellem Turn eingereiht)',
    'pt': 'Enviar (entrará na fila após o turno atual)',
    'it': 'Invia (sarà accodato dopo il turno corrente)',
})
add('chat', 'err_billing', {
    'en': 'Billing Error',
    'fr': 'Erreur de facturation',
    'es': 'Error de facturación',
    'de': 'Abrechnungsfehler',
    'pt': 'Erro de faturamento',
    'it': 'Errore di fatturazione',
})
add('chat', 'err_auth', {
    'en': 'Authentication Error',
    'fr': "Erreur d'authentification",
    'es': 'Error de autenticación',
    'de': 'Authentifizierungsfehler',
    'pt': 'Erro de autenticação',
    'it': 'Errore di autenticazione',
})
add('chat', 'err_rate_limit', {
    'en': 'Rate Limited',
    'fr': 'Débit limité',
    'es': 'Límite de tasa',
    'de': 'Ratenlimit',
    'pt': 'Limite de taxa',
    'it': 'Limite di velocità',
})
add('chat', 'err_provider', {
    'en': 'Provider Error',
    'fr': 'Erreur du fournisseur',
    'es': 'Error del proveedor',
    'de': 'Anbieter-Fehler',
    'pt': 'Erro do provedor',
    'it': 'Errore del fornitore',
})
add('chat', 'err_network', {
    'en': 'Network Error',
    'fr': 'Erreur réseau',
    'es': 'Error de red',
    'de': 'Netzwerkfehler',
    'pt': 'Erro de rede',
    'it': 'Errore di rete',
})
add('chat', 'err_security', {
    'en': 'Permission Denied',
    'fr': 'Accès refusé',
    'es': 'Permiso denegado',
    'de': 'Zugriff verweigert',
    'pt': 'Permissão negada',
    'it': 'Autorizzazione negata',
})
add('chat', 'err_generic', {
    'en': 'Error',
    'fr': 'Erreur',
    'es': 'Error',
    'de': 'Fehler',
    'pt': 'Erro',
    'it': 'Errore',
})
add('chat', 'hide_details', {
    'en': 'Hide details',
    'fr': 'Masquer les détails',
    'es': 'Ocultar detalles',
    'de': 'Details ausblenden',
    'pt': 'Ocultar detalhes',
    'it': 'Nascondi dettagli',
})
add('chat', 'show_details', {
    'en': 'Show details',
    'fr': 'Afficher les détails',
    'es': 'Mostrar detalles',
    'de': 'Details anzeigen',
    'pt': 'Mostrar detalhes',
    'it': 'Mostra dettagli',
})
add('chat', 'retry', {
    'en': 'Retry',
    'fr': 'Réessayer',
    'es': 'Reintentar',
    'de': 'Wiederholen',
    'pt': 'Tentar novamente',
    'it': 'Riprova',
})
add('chat', 'dismiss', {
    'en': 'Dismiss',
    'fr': 'Ignorer',
    'es': 'Descartar',
    'de': 'Schließen',
    'pt': 'Dispensar',
    'it': 'Ignora',
})
add('chat', 'drop_to_attach', {
    'en': 'Drop to attach',
    'fr': 'Déposer pour joindre',
    'es': 'Soltar para adjuntar',
    'de': 'Loslassen zum Anhängen',
    'pt': 'Solte para anexar',
    'it': 'Rilascia per allegare',
})
add('chat', 'drop_multiple_files_hint', {
    'en': 'Multiple files are supported · images get a live thumbnail',
    'fr': 'Plusieurs fichiers sont pris en charge · les images affichent une miniature en direct',
    'es': 'Se admiten varios archivos · las imágenes muestran una miniatura en vivo',
    'de': 'Mehrere Dateien werden unterstützt · Bilder erhalten eine Live-Vorschau',
    'pt': 'Vários arquivos são suportados · imagens recebem miniatura ao vivo',
    'it': 'Sono supportati più file · le immagini mostrano un’anteprima live',
})
add('chat', 'clear_short', {
    'en': 'Clear',
    'fr': 'Effacer',
    'es': 'Borrar',
    'de': 'Löschen',
    'pt': 'Limpar',
    'it': 'Cancella',
})
add('chat', 'rate_limited_with', {
    'en': 'Rate limited · {reason}',
    'fr': 'Débit limité · {reason}',
    'es': 'Límite de tasa · {reason}',
    'de': 'Ratenlimit · {reason}',
    'pt': 'Limite de taxa · {reason}',
    'it': 'Limite di velocità · {reason}',
})
add('chat', 'rate_limited', {
    'en': 'Rate limited',
    'fr': 'Débit limité',
    'es': 'Límite de tasa',
    'de': 'Ratenlimit',
    'pt': 'Limite de taxa',
    'it': 'Limite di velocità',
})
add('chat', 'compacting_context', {
    'en': 'Compacting context',
    'fr': 'Compactage du contexte',
    'es': 'Compactando contexto',
    'de': 'Kontext wird komprimiert',
    'pt': 'Compactando contexto',
    'it': 'Compattamento contesto',
})
add('chat', 'interrupted_resume_hint', {
    'en': 'Interrupted — send a message to resume',
    'fr': 'Interrompu — envoyez un message pour reprendre',
    'es': 'Interrumpido — envía un mensaje para reanudar',
    'de': 'Unterbrochen — Nachricht senden zum Fortsetzen',
    'pt': 'Interrompido — envie uma mensagem para retomar',
    'it': 'Interrotto — invia un messaggio per riprendere',
})
add('chat', 'aborting', {
    'en': 'Aborting…',
    'fr': 'Interruption…',
    'es': 'Abortando…',
    'de': 'Abbrechen…',
    'pt': 'Abortando…',
    'it': 'Interruzione…',
})
add('chat', 'resuming', {
    'en': 'Resuming…',
    'fr': 'Reprise…',
    'es': 'Reanudando…',
    'de': 'Fortsetzen…',
    'pt': 'Retomando…',
    'it': 'Ripresa…',
})


# Apply
for lang in LANGS:
    path = ROOT + lang + '.json'
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    for ns, keys in ADDITIONS.items():
        data.setdefault(ns, {})
        for k, tr in keys.items():
            data[ns][k] = tr[lang]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
print('Added', sum(len(v) for v in ADDITIONS.values()), 'keys to each of', len(LANGS), 'files')
