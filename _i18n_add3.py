import json
ROOT = 'C:/Users/ASUS/Documents/digitorn_client/assets/translations/'
LANGS = ['en', 'fr', 'es', 'de', 'pt', 'it']

KEYS = {
    'session_payload': {
        'en': 'Session payload', 'fr': 'Payload de session', 'es': 'Payload de sesión',
        'de': 'Session-Payload', 'pt': 'Payload da sessão', 'it': 'Payload sessione'
    },
    'session_preferences': {
        'en': 'Session preferences', 'fr': 'Préférences de session', 'es': 'Preferencias de sesión',
        'de': 'Session-Einstellungen', 'pt': 'Preferências da sessão', 'it': 'Preferenze sessione'
    },
    'session_short': {
        'en': 'Session', 'fr': 'Session', 'es': 'Sesión',
        'de': 'Sitzung', 'pt': 'Sessão', 'it': 'Sessione'
    },
    'test_now': {
        'en': 'Test now', 'fr': 'Tester maintenant', 'es': 'Probar ahora',
        'de': 'Jetzt testen', 'pt': 'Testar agora', 'it': 'Prova ora'
    },
    'clear': {
        'en': 'Clear', 'fr': 'Effacer', 'es': 'Borrar',
        'de': 'Löschen', 'pt': 'Limpar', 'it': 'Cancella'
    },
    'clear_payload_confirm_title': {
        'en': 'Clear payload?', 'fr': 'Effacer le payload ?', 'es': '¿Borrar payload?',
        'de': 'Payload löschen?', 'pt': 'Limpar payload?', 'it': 'Cancellare il payload?'
    },
    'clear_payload_confirm_body': {
        'en': 'This removes the prompt, all preferences, and every attached file from this session. Cannot be undone.',
        'fr': 'Cette action supprime le prompt, toutes les préférences et chaque fichier joint à cette session. Action irréversible.',
        'es': 'Esto elimina el prompt, todas las preferencias y todos los archivos adjuntos de esta sesión. No se puede deshacer.',
        'de': 'Dies entfernt den Prompt, alle Einstellungen und jede angehängte Datei aus dieser Session. Nicht rückgängig zu machen.',
        'pt': 'Isso remove o prompt, todas as preferências e todos os arquivos anexados desta sessão. Não pode ser desfeito.',
        'it': 'Questo rimuove il prompt, tutte le preferenze e ogni file allegato da questa sessione. Non può essere annullato.',
    },
    'cancel': {
        'en': 'Cancel', 'fr': 'Annuler', 'es': 'Cancelar',
        'de': 'Abbrechen', 'pt': 'Cancelar', 'it': 'Annulla'
    },
    'prompt_saved_toast': {
        'en': 'Prompt saved', 'fr': 'Prompt enregistré', 'es': 'Prompt guardado',
        'de': 'Prompt gespeichert', 'pt': 'Prompt salvo', 'it': 'Prompt salvato'
    },
    'preferences_saved_toast': {
        'en': 'Preferences saved', 'fr': 'Préférences enregistrées', 'es': 'Preferencias guardadas',
        'de': 'Einstellungen gespeichert', 'pt': 'Preferências salvas', 'it': 'Preferenze salvate'
    },
    'uploaded_toast': {
        'en': 'Uploaded {name}', 'fr': '{name} téléversé', 'es': '{name} subido',
        'de': '{name} hochgeladen', 'pt': '{name} enviado', 'it': '{name} caricato'
    },
    'removed_toast': {
        'en': 'Removed {name}', 'fr': '{name} supprimé', 'es': '{name} eliminado',
        'de': '{name} entfernt', 'pt': '{name} removido', 'it': '{name} rimosso'
    },
    'trigger_fired_toast': {
        'en': 'Trigger "{type}" fired — check Activations',
        'fr': 'Déclencheur « {type} » activé — consultez les activations',
        'es': 'Disparador «{type}» activado — revisa Activaciones',
        'de': 'Trigger "{type}" ausgelöst — siehe Aktivierungen',
        'pt': 'Gatilho "{type}" disparado — veja Ativações',
        'it': 'Trigger "{type}" attivato — controlla Attivazioni',
    },
    'trigger_fire_failed': {
        'en': 'Failed to fire trigger', 'fr': "Échec du déclenchement",
        'es': 'No se pudo activar el disparador', 'de': 'Trigger konnte nicht ausgelöst werden',
        'pt': 'Falha ao disparar o gatilho', 'it': 'Impossibile attivare il trigger'
    },
    'payload_cleared_toast': {
        'en': 'Payload cleared', 'fr': 'Payload effacé', 'es': 'Payload borrado',
        'de': 'Payload gelöscht', 'pt': 'Payload limpo', 'it': 'Payload cancellato'
    },
    'failed_to_load_payload': {
        'en': 'Failed to load payload', 'fr': 'Échec du chargement du payload',
        'es': 'Error al cargar el payload', 'de': 'Payload konnte nicht geladen werden',
        'pt': 'Falha ao carregar payload', 'it': 'Impossibile caricare il payload'
    },
    'retry': {
        'en': 'Retry', 'fr': 'Réessayer', 'es': 'Reintentar',
        'de': 'Wiederholen', 'pt': 'Tentar novamente', 'it': 'Riprova'
    },
    'payload_required_title': {
        'en': 'Payload required', 'fr': 'Payload requis', 'es': 'Payload requerido',
        'de': 'Payload erforderlich', 'pt': 'Payload obrigatório', 'it': 'Payload richiesto'
    },
    'configured_scheduled_triggers': {
        'en': 'Configured for scheduled triggers',
        'fr': 'Configuré pour les déclencheurs planifiés',
        'es': 'Configurado para disparadores programados',
        'de': 'Für geplante Trigger konfiguriert',
        'pt': 'Configurado para gatilhos agendados',
        'it': 'Configurato per trigger programmati'
    },
    'mode_required_body_no_summary': {
        'en': "This app fires on a schedule. Without a prompt the agent has nothing to do at each tick — fill the form below before activating.",
        'fr': "Cette application se déclenche selon un planning. Sans prompt, l'agent n'a rien à faire à chaque tick — remplissez le formulaire ci-dessous avant d'activer.",
        'es': 'Esta aplicación se dispara según un horario. Sin un prompt el agente no tendrá nada que hacer en cada tick — rellena el formulario antes de activar.',
        'de': 'Diese App läuft nach einem Zeitplan. Ohne Prompt hat der Agent bei jedem Tick nichts zu tun — füllen Sie das Formular unten aus, bevor Sie aktivieren.',
        'pt': 'Este app dispara em um cronograma. Sem um prompt o agente não tem nada a fazer a cada tick — preencha o formulário antes de ativar.',
        'it': 'Questa app si attiva secondo una pianificazione. Senza prompt l\'agente non ha nulla da fare a ogni tick — compila il modulo prima di attivare.'
    },
    'mode_required_body_with_summary': {
        'en': '{summary} fires automatically. The agent re-uses your prompt + files + preferences at every tick — fill them in below.',
        'fr': '{summary} se déclenche automatiquement. L\'agent réutilise votre prompt + fichiers + préférences à chaque tick — remplissez-les ci-dessous.',
        'es': '{summary} se dispara automáticamente. El agente reutiliza tu prompt + archivos + preferencias en cada tick — complétalos abajo.',
        'de': '{summary} wird automatisch ausgelöst. Der Agent verwendet Ihren Prompt + Dateien + Einstellungen bei jedem Tick — füllen Sie diese unten aus.',
        'pt': '{summary} dispara automaticamente. O agente reutiliza seu prompt + arquivos + preferências a cada tick — preencha abaixo.',
        'it': '{summary} si attiva automaticamente. L\'agente riutilizza il tuo prompt + file + preferenze a ogni tick — compilali qui sotto.'
    },
    'mode_mixed_title': {
        'en': 'Mixed triggers', 'fr': 'Déclencheurs mixtes', 'es': 'Disparadores mixtos',
        'de': 'Gemischte Trigger', 'pt': 'Gatilhos mistos', 'it': 'Trigger misti'
    },
    'mode_mixed_body': {
        'en': 'Some triggers fire automatically (need a prompt), others receive live messages from users (preferences only). Configure both to cover every case.',
        'fr': "Certains déclencheurs se déclenchent automatiquement (nécessitent un prompt), d'autres reçoivent des messages en direct (préférences uniquement). Configurez les deux pour couvrir tous les cas.",
        'es': 'Algunos disparadores se activan automáticamente (necesitan un prompt), otros reciben mensajes en vivo (solo preferencias). Configura ambos para cubrir todos los casos.',
        'de': 'Einige Trigger werden automatisch ausgelöst (benötigen Prompt), andere empfangen Live-Nachrichten von Benutzern (nur Einstellungen). Konfigurieren Sie beides für jeden Fall.',
        'pt': 'Alguns gatilhos disparam automaticamente (precisam de prompt), outros recebem mensagens ao vivo dos usuários (só preferências). Configure ambos para cobrir todos os casos.',
        'it': 'Alcuni trigger si attivano automaticamente (richiedono prompt), altri ricevono messaggi live dagli utenti (solo preferenze). Configura entrambi per coprire ogni caso.'
    },
    'mode_optional_title': {
        'en': 'Preferences (optional)', 'fr': 'Préférences (optionnel)',
        'es': 'Preferencias (opcional)', 'de': 'Einstellungen (optional)',
        'pt': 'Preferências (opcional)', 'it': 'Preferenze (facoltativo)'
    },
    'mode_optional_body_no_summary': {
        'en': "This app reacts to live messages — the user's text is the agent input. Use this page only to set permanent instructions or attach files reused on every conversation.",
        'fr': "Cette application réagit aux messages en direct — le texte de l'utilisateur est l'entrée de l'agent. Utilisez cette page uniquement pour définir des instructions permanentes ou joindre des fichiers réutilisés à chaque conversation.",
        'es': 'Esta aplicación reacciona a mensajes en vivo — el texto del usuario es la entrada del agente. Usa esta página solo para establecer instrucciones permanentes o adjuntar archivos reutilizados en cada conversación.',
        'de': 'Diese App reagiert auf Live-Nachrichten — der Text des Benutzers ist die Agenten-Eingabe. Verwenden Sie diese Seite nur für permanente Anweisungen oder für Dateien, die bei jeder Konversation wiederverwendet werden.',
        'pt': 'Este app reage a mensagens ao vivo — o texto do usuário é a entrada do agente. Use esta página apenas para definir instruções permanentes ou anexar arquivos reutilizados em cada conversa.',
        'it': "Questa app reagisce ai messaggi live — il testo dell'utente è l'input dell'agente. Usa questa pagina solo per impostare istruzioni permanenti o allegare file riutilizzati in ogni conversazione."
    },
    'mode_optional_body_with_summary': {
        'en': "This app reacts to live messages over {summary}. The user's text is the agent input — use this page only for permanent instructions or files reused at every conversation.",
        'fr': "Cette application réagit aux messages en direct sur {summary}. Le texte de l'utilisateur est l'entrée de l'agent — utilisez cette page uniquement pour les instructions permanentes ou les fichiers réutilisés à chaque conversation.",
        'es': 'Esta aplicación reacciona a mensajes en vivo sobre {summary}. El texto del usuario es la entrada del agente — usa esta página solo para instrucciones permanentes o archivos reutilizados en cada conversación.',
        'de': 'Diese App reagiert auf Live-Nachrichten über {summary}. Der Text des Benutzers ist die Agenten-Eingabe — verwenden Sie diese Seite nur für permanente Anweisungen oder für Dateien, die bei jeder Konversation wiederverwendet werden.',
        'pt': 'Este app reage a mensagens ao vivo em {summary}. O texto do usuário é a entrada do agente — use esta página apenas para instruções permanentes ou arquivos reutilizados em cada conversa.',
        'it': "Questa app reagisce ai messaggi live su {summary}. Il testo dell'utente è l'input dell'agente — usa questa pagina solo per istruzioni permanenti o file riutilizzati in ogni conversazione."
    },
    'prompt_required_label': {
        'en': 'PROMPT *', 'fr': 'PROMPT *', 'es': 'PROMPT *',
        'de': 'PROMPT *', 'pt': 'PROMPT *', 'it': 'PROMPT *'
    },
    'prompt_required_hint': {
        'en': 'Required — the agent uses this verbatim at every scheduled tick',
        'fr': "Requis — l'agent l'utilise tel quel à chaque tick planifié",
        'es': 'Obligatorio — el agente lo usa tal cual en cada tick programado',
        'de': 'Erforderlich — der Agent verwendet dies wörtlich bei jedem geplanten Tick',
        'pt': 'Obrigatório — o agente usa isso literalmente a cada tick agendado',
        'it': "Richiesto — l'agente lo usa alla lettera a ogni tick programmato"
    },
    'prompt_required_placeholder': {
        'en': 'Find me remote Python jobs paying at least 80k€/year. Filter out contract roles.',
        'fr': 'Trouve-moi des emplois Python à distance payant au moins 80k€/an. Exclus les contrats.',
        'es': 'Encuéntrame trabajos remotos de Python que paguen al menos 80k€/año. Filtra los contratos.',
        'de': 'Finde mir Remote-Python-Jobs mit mindestens 80k€/Jahr. Vertragsrollen ausfiltern.',
        'pt': 'Encontre empregos Python remotos pagando pelo menos 80k€/ano. Filtre contratos.',
        'it': 'Trovami lavori Python da remoto che pagano almeno 80k€/anno. Escludi i ruoli a contratto.'
    },
    'prompt_label': {
        'en': 'PROMPT', 'fr': 'PROMPT', 'es': 'PROMPT',
        'de': 'PROMPT', 'pt': 'PROMPT', 'it': 'PROMPT'
    },
    'prompt_recommended_hint': {
        'en': 'Used by scheduled triggers; conversational triggers append it as context',
        'fr': 'Utilisé par les déclencheurs planifiés ; les déclencheurs conversationnels l\'ajoutent comme contexte',
        'es': 'Usado por disparadores programados; los conversacionales lo añaden como contexto',
        'de': 'Wird von geplanten Triggern verwendet; Konversations-Trigger hängen es als Kontext an',
        'pt': 'Usado por gatilhos agendados; os conversacionais anexam como contexto',
        'it': 'Usato dai trigger programmati; i trigger conversazionali lo aggiungono come contesto'
    },
    'prompt_recommended_placeholder': {
        'en': 'Daily summary of all unread emails labeled "important", in 5 bullet points.',
        'fr': 'Résumé quotidien des e-mails non lus étiquetés « important », en 5 puces.',
        'es': 'Resumen diario de todos los correos no leídos con etiqueta "importante", en 5 viñetas.',
        'de': 'Tägliche Zusammenfassung aller ungelesenen E-Mails mit dem Label "wichtig", in 5 Aufzählungspunkten.',
        'pt': 'Resumo diário de todos os e-mails não lidos marcados como "importante", em 5 tópicos.',
        'it': 'Riepilogo giornaliero di tutte le email non lette etichettate "importante", in 5 punti elenco.'
    },
    'permanent_instructions_label': {
        'en': 'PERMANENT INSTRUCTIONS', 'fr': 'INSTRUCTIONS PERMANENTES',
        'es': 'INSTRUCCIONES PERMANENTES', 'de': 'PERMANENTE ANWEISUNGEN',
        'pt': 'INSTRUÇÕES PERMANENTES', 'it': 'ISTRUZIONI PERMANENTI'
    },
    'permanent_instructions_hint': {
        'en': 'Optional context appended to every incoming message',
        'fr': 'Contexte facultatif ajouté à chaque message entrant',
        'es': 'Contexto opcional añadido a cada mensaje entrante',
        'de': 'Optionaler Kontext, der jeder eingehenden Nachricht angehängt wird',
        'pt': 'Contexto opcional anexado a cada mensagem recebida',
        'it': 'Contesto facoltativo aggiunto a ogni messaggio in arrivo'
    },
    'permanent_instructions_placeholder': {
        'en': 'You are the support assistant for ACME. Always answer in French and stay concise.',
        'fr': "Vous êtes l'assistant support d'ACME. Répondez toujours en français et restez concis.",
        'es': 'Eres el asistente de soporte de ACME. Responde siempre en francés y sé conciso.',
        'de': 'Du bist der Support-Assistent von ACME. Antworte immer auf Französisch und bleibe kurz.',
        'pt': 'Você é o assistente de suporte da ACME. Sempre responda em francês e seja conciso.',
        'it': "Sei l'assistente di supporto di ACME. Rispondi sempre in francese e resta conciso."
    },
    'prompt_hidden_hint': {
        'en': 'Optional context for the agent',
        'fr': "Contexte facultatif pour l'agent",
        'es': 'Contexto opcional para el agente',
        'de': 'Optionaler Kontext für den Agenten',
        'pt': 'Contexto opcional para o agente',
        'it': "Contesto facoltativo per l'agente"
    },
    'chars_counter': {
        'en': '{current} / {max} chars',
        'fr': '{current} / {max} caractères',
        'es': '{current} / {max} caracteres',
        'de': '{current} / {max} Zeichen',
        'pt': '{current} / {max} caracteres',
        'it': '{current} / {max} caratteri'
    },
    'unsaved_badge': {
        'en': 'UNSAVED', 'fr': 'NON ENREGISTRÉ', 'es': 'SIN GUARDAR',
        'de': 'NICHT GESPEICHERT', 'pt': 'NÃO SALVO', 'it': 'NON SALVATO'
    },
    'save_short': {
        'en': 'Save', 'fr': 'Enregistrer', 'es': 'Guardar',
        'de': 'Speichern', 'pt': 'Salvar', 'it': 'Salva'
    },
    'preferences_label': {
        'en': 'PREFERENCES', 'fr': 'PRÉFÉRENCES', 'es': 'PREFERENCIAS',
        'de': 'EINSTELLUNGEN', 'pt': 'PREFERÊNCIAS', 'it': 'PREFERENZE'
    },
    'preferences_hint': {
        'en': 'Structured key/value pairs sent to the agent as context',
        'fr': "Paires clé/valeur structurées envoyées à l'agent comme contexte",
        'es': 'Pares clave/valor estructurados enviados al agente como contexto',
        'de': 'Strukturierte Schlüssel/Wert-Paare, die als Kontext an den Agenten gesendet werden',
        'pt': 'Pares chave/valor estruturados enviados ao agente como contexto',
        'it': "Coppie chiave/valore strutturate inviate all'agente come contesto"
    },
    'preference_count': {
        'en': '{n} preference(s)', 'fr': '{n} préférence(s)', 'es': '{n} preferencia(s)',
        'de': '{n} Einstellung(en)', 'pt': '{n} preferência(s)', 'it': '{n} preferenza/e'
    },
    'add_preference': {
        'en': 'Add preference', 'fr': 'Ajouter une préférence', 'es': 'Añadir preferencia',
        'de': 'Einstellung hinzufügen', 'pt': 'Adicionar preferência', 'it': 'Aggiungi preferenza'
    },
    'key_hint': {
        'en': 'key', 'fr': 'clé', 'es': 'clave',
        'de': 'Schlüssel', 'pt': 'chave', 'it': 'chiave'
    },
    'value_hint': {
        'en': 'value', 'fr': 'valeur', 'es': 'valor',
        'de': 'Wert', 'pt': 'valor', 'it': 'valore'
    },
    'remove': {
        'en': 'Remove', 'fr': 'Supprimer', 'es': 'Eliminar',
        'de': 'Entfernen', 'pt': 'Remover', 'it': 'Rimuovi'
    },
    'attachments_label': {
        'en': 'ATTACHMENTS', 'fr': 'PIÈCES JOINTES', 'es': 'ADJUNTOS',
        'de': 'ANHÄNGE', 'pt': 'ANEXOS', 'it': 'ALLEGATI'
    },
    'attachments_hint': {
        'en': 'Files re-injected into every activation',
        'fr': 'Fichiers réinjectés à chaque activation',
        'es': 'Archivos reinyectados en cada activación',
        'de': 'Dateien, die bei jeder Aktivierung erneut eingefügt werden',
        'pt': 'Arquivos reinjetados em cada ativação',
        'it': 'File reinseriti in ogni attivazione'
    },
    'max_file_size': {
        'en': 'Max 25 MB per file', 'fr': 'Max 25 Mo par fichier', 'es': 'Máx 25 MB por archivo',
        'de': 'Max. 25 MB pro Datei', 'pt': 'Máx 25 MB por arquivo', 'it': 'Max 25 MB per file'
    },
    'uploading': {
        'en': 'Uploading {name}', 'fr': 'Téléversement de {name}', 'es': 'Subiendo {name}',
        'de': 'Lade {name} hoch', 'pt': 'Enviando {name}', 'it': 'Caricamento di {name}'
    },
    'drop_files_upload': {
        'en': 'Drop files to upload', 'fr': 'Déposer les fichiers pour téléverser',
        'es': 'Suelta los archivos para subirlos', 'de': 'Dateien zum Hochladen hier ablegen',
        'pt': 'Solte os arquivos para enviar', 'it': 'Rilascia i file per caricare'
    },
    'drop_or_click': {
        'en': 'Drop files here, or click to browse',
        'fr': 'Déposez les fichiers ici ou cliquez pour parcourir',
        'es': 'Suelta los archivos aquí o haz clic para buscar',
        'de': 'Dateien hier ablegen oder klicken, um zu durchsuchen',
        'pt': 'Solte os arquivos aqui ou clique para procurar',
        'it': 'Rilascia i file qui o clicca per sfogliare'
    },
    'supported_formats': {
        'en': 'PDF · text · images · CSV · JSON',
        'fr': 'PDF · texte · images · CSV · JSON',
        'es': 'PDF · texto · imágenes · CSV · JSON',
        'de': 'PDF · Text · Bilder · CSV · JSON',
        'pt': 'PDF · texto · imagens · CSV · JSON',
        'it': 'PDF · testo · immagini · CSV · JSON'
    },
}

for lang in LANGS:
    path = ROOT + lang + '.json'
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    ns = data.setdefault('background_extra', {})
    for key, tr in KEYS.items():
        ns[key] = tr[lang]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
print('done')
