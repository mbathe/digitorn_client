"""Grants-related keys."""
import json
packs = {
    "en": {
        "grants_of": "Grants · {name}",
        "grants_subtitle": "Apps with access to this credential. Revoke an app to make it ask again on its next run.",
        "grants_empty": "No app uses this credential yet.",
        "revoke": "Revoke"
    },
    "fr": {
        "grants_of": "Accès · {name}",
        "grants_subtitle": "Applications ayant accès à cet identifiant. Révoquez une app pour qu'elle redemande à sa prochaine exécution.",
        "grants_empty": "Aucune app n'utilise encore cet identifiant.",
        "revoke": "Révoquer"
    },
    "es": {
        "grants_of": "Permisos · {name}",
        "grants_subtitle": "Apps con acceso a esta credencial. Revoca una app para que vuelva a pedirla en su próxima ejecución.",
        "grants_empty": "Ninguna app usa aún esta credencial.",
        "revoke": "Revocar"
    },
    "de": {
        "grants_of": "Zugriffe · {name}",
        "grants_subtitle": "Apps mit Zugriff auf diese Anmeldedaten. Widerrufe eine App, damit sie beim nächsten Start erneut fragt.",
        "grants_empty": "Keine App nutzt diese Anmeldedaten bisher.",
        "revoke": "Widerrufen"
    },
    "pt": {
        "grants_of": "Concessões · {name}",
        "grants_subtitle": "Apps com acesso a esta credencial. Revogue uma app para que peça novamente na próxima execução.",
        "grants_empty": "Nenhuma app usa ainda esta credencial.",
        "revoke": "Revogar"
    },
    "it": {
        "grants_of": "Permessi · {name}",
        "grants_subtitle": "App con accesso a questa credenziale. Revoca un'app per farla richiedere di nuovo alla prossima esecuzione.",
        "grants_empty": "Nessuna app usa ancora questa credenziale.",
        "revoke": "Revoca"
    }
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('credentials', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
