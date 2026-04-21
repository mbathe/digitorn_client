"""Extra approval keys."""
import json
packs = {
    "en": {
        "approvals_scanning": "Scanning every app for pending approvals…",
        "approvals_pending_count": "{n} pending request(s) across {apps} app(s).",
        "approvals_all_clear": "All clear",
        "approvals_no_pending": "No pending approvals in any app right now.",
        "approvals_no_preview": "(no preview)",
        "approvals_by": "by {actor}",
        "approvals_session": "session {id}",
        "approvals_id": "id {id}",
        "approvals_resolve_failed": "Resolve failed — check logs."
    },
    "fr": {
        "approvals_scanning": "Analyse de toutes les apps pour les approbations…",
        "approvals_pending_count": "{n} demande(s) en attente sur {apps} app(s).",
        "approvals_all_clear": "Tout est bon",
        "approvals_no_pending": "Aucune approbation en attente pour l'instant.",
        "approvals_no_preview": "(aucun aperçu)",
        "approvals_by": "par {actor}",
        "approvals_session": "session {id}",
        "approvals_id": "id {id}",
        "approvals_resolve_failed": "Résolution échouée — vérifiez les logs."
    },
    "es": {
        "approvals_scanning": "Escaneando todas las apps por aprobaciones…",
        "approvals_pending_count": "{n} solicitud(es) pendiente(s) en {apps} app(s).",
        "approvals_all_clear": "Todo en orden",
        "approvals_no_pending": "Sin aprobaciones pendientes en ninguna app.",
        "approvals_no_preview": "(sin vista previa)",
        "approvals_by": "por {actor}",
        "approvals_session": "sesión {id}",
        "approvals_id": "id {id}",
        "approvals_resolve_failed": "Resolución fallida — revisa los logs."
    },
    "de": {
        "approvals_scanning": "Alle Apps auf ausstehende Genehmigungen scannen…",
        "approvals_pending_count": "{n} ausstehende Anfrage(n) über {apps} App(s).",
        "approvals_all_clear": "Alles in Ordnung",
        "approvals_no_pending": "Keine ausstehenden Genehmigungen.",
        "approvals_no_preview": "(keine Vorschau)",
        "approvals_by": "von {actor}",
        "approvals_session": "Sitzung {id}",
        "approvals_id": "id {id}",
        "approvals_resolve_failed": "Lösung fehlgeschlagen — prüfe die Logs."
    },
    "pt": {
        "approvals_scanning": "Verificando todas as apps por aprovações pendentes…",
        "approvals_pending_count": "{n} solicitação(ões) pendente(s) em {apps} app(s).",
        "approvals_all_clear": "Tudo certo",
        "approvals_no_pending": "Sem aprovações pendentes em nenhuma app.",
        "approvals_no_preview": "(sem prévia)",
        "approvals_by": "por {actor}",
        "approvals_session": "sessão {id}",
        "approvals_id": "id {id}",
        "approvals_resolve_failed": "Resolução falhou — verifique os logs."
    },
    "it": {
        "approvals_scanning": "Scansione di tutte le app per approvazioni in sospeso…",
        "approvals_pending_count": "{n} richiesta/e in sospeso su {apps} app.",
        "approvals_all_clear": "Tutto a posto",
        "approvals_no_pending": "Nessuna approvazione in sospeso al momento.",
        "approvals_no_preview": "(nessuna anteprima)",
        "approvals_by": "da {actor}",
        "approvals_session": "sessione {id}",
        "approvals_id": "id {id}",
        "approvals_resolve_failed": "Risoluzione fallita — controlla i log."
    }
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('admin', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
