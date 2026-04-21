"""Admin section subtitles."""
import json
packs = {
    "en": {
        "overview_subtitle": "Workspace health at a glance. Numbers refresh on every section open.",
        "users_subtitle": "{n} registered · click a row for details, edits and session management.",
        "quotas_subtitle": "Token-budget rules per user, per app or per team. Daemon enforces them at runtime.",
        "sys_creds_subtitle": "Workspace-shared API keys. Every user can use them without configuring their own.",
        "mcp_subtitle": "Shared MCP instances reused across users. Connect / disconnect at will — uninstall lives in the Hub.",
        "sys_pkgs_subtitle": "Apps installed for every user on this daemon. Personal installs live in each user's own library.",
        "audit_subtitle": "{n} admin action(s) recorded — newest first."
    },
    "fr": {
        "overview_subtitle": "Santé de l'espace en un coup d'œil. Les chiffres se rafraîchissent à chaque ouverture.",
        "users_subtitle": "{n} inscrits · cliquez une ligne pour détails, modifications et gestion des sessions.",
        "quotas_subtitle": "Règles de budget tokens par utilisateur, par app ou par équipe. Le daemon les applique à l'exécution.",
        "sys_creds_subtitle": "Clés API partagées de l'espace. Chaque utilisateur peut les utiliser sans configurer les siennes.",
        "mcp_subtitle": "Instances MCP partagées réutilisées par les utilisateurs. Connecter / déconnecter à volonté — désinstaller depuis le Hub.",
        "sys_pkgs_subtitle": "Applications installées pour tous les utilisateurs de ce daemon. Les installations personnelles sont dans la bibliothèque de chacun.",
        "audit_subtitle": "{n} action(s) admin enregistrée(s) — plus récentes en premier."
    },
    "es": {
        "overview_subtitle": "Salud del espacio de un vistazo. Los números se actualizan al abrir cada sección.",
        "users_subtitle": "{n} registrados · haz clic en una fila para detalles, ediciones y gestión de sesiones.",
        "quotas_subtitle": "Reglas de presupuesto de tokens por usuario, app o equipo. El daemon las aplica en tiempo de ejecución.",
        "sys_creds_subtitle": "Claves API compartidas del espacio. Cada usuario puede usarlas sin configurar las suyas.",
        "mcp_subtitle": "Instancias MCP compartidas reutilizadas entre usuarios. Conecta/desconecta a voluntad — desinstalar está en el Hub.",
        "sys_pkgs_subtitle": "Apps instaladas para cada usuario de este daemon. Las instalaciones personales están en la biblioteca de cada uno.",
        "audit_subtitle": "{n} acción(es) de admin registrada(s) — más recientes primero."
    },
    "de": {
        "overview_subtitle": "Workspace-Zustand auf einen Blick. Zahlen aktualisieren sich beim Öffnen jedes Abschnitts.",
        "users_subtitle": "{n} registriert · Klicke eine Zeile für Details, Bearbeitungen und Sitzungsverwaltung.",
        "quotas_subtitle": "Token-Budget-Regeln pro Benutzer, App oder Team. Der Daemon erzwingt sie zur Laufzeit.",
        "sys_creds_subtitle": "Workspace-geteilte API-Schlüssel. Jeder Benutzer kann sie ohne eigene Konfiguration verwenden.",
        "mcp_subtitle": "Geteilte MCP-Instanzen, die von Benutzern wiederverwendet werden. Verbinden/Trennen beliebig — Deinstallation im Hub.",
        "sys_pkgs_subtitle": "Apps installiert für jeden Benutzer auf diesem Daemon. Persönliche Installationen sind in der Bibliothek jedes Einzelnen.",
        "audit_subtitle": "{n} Admin-Aktion(en) aufgezeichnet — neueste zuerst."
    },
    "pt": {
        "overview_subtitle": "Saúde do workspace de relance. Os números atualizam ao abrir cada seção.",
        "users_subtitle": "{n} registrados · clique numa linha para detalhes, edições e gerenciamento de sessões.",
        "quotas_subtitle": "Regras de orçamento de tokens por usuário, app ou equipe. O daemon as aplica em tempo de execução.",
        "sys_creds_subtitle": "Chaves de API compartilhadas do workspace. Todo usuário pode usá-las sem configurar as suas.",
        "mcp_subtitle": "Instâncias MCP compartilhadas reutilizadas entre usuários. Conecte/desconecte à vontade — desinstalar fica no Hub.",
        "sys_pkgs_subtitle": "Apps instalados para cada usuário neste daemon. Instalações pessoais ficam na biblioteca de cada um.",
        "audit_subtitle": "{n} ação(ões) de admin registrada(s) — mais recentes primeiro."
    },
    "it": {
        "overview_subtitle": "Stato del workspace a colpo d'occhio. I numeri si aggiornano ad ogni apertura di sezione.",
        "users_subtitle": "{n} registrati · clicca una riga per dettagli, modifiche e gestione sessioni.",
        "quotas_subtitle": "Regole di budget token per utente, per app o per team. Il daemon le applica a runtime.",
        "sys_creds_subtitle": "Chiavi API condivise del workspace. Ogni utente può usarle senza configurare le proprie.",
        "mcp_subtitle": "Istanze MCP condivise riutilizzate tra utenti. Connetti/disconnetti a piacimento — disinstallazione nell'Hub.",
        "sys_pkgs_subtitle": "App installate per ogni utente su questo daemon. Le installazioni personali sono nella libreria di ciascuno.",
        "audit_subtitle": "{n} azione/i admin registrata/e — più recenti prima."
    }
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('admin', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
