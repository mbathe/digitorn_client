"""Welcome + scale row keys."""
import json

packs = {
    "en": {
        "welcome_eyebrow": "WELCOME",
        "welcome_title_long": "The runtime for\nagentic apps.",
        "welcome_subtitle_long": "Install hundreds of agents from the Hub. Build your own in minutes with Digitorn Builder. One premium runtime for everything.",
        "welcome_cta": "Get started",
        "stat_hub_label": "Agentic apps in the Hub",
        "stat_builder_label": "To build your own with Builder",
        "stat_runtime_label": "Self-hosted, your data"
    },
    "fr": {
        "welcome_eyebrow": "BIENVENUE",
        "welcome_title_long": "Le runtime pour\napps agentiques.",
        "welcome_subtitle_long": "Installez des centaines d'agents depuis le Hub. Créez les vôtres en quelques minutes avec Digitorn Builder. Un seul runtime premium pour tout.",
        "welcome_cta": "Commencer",
        "stat_hub_label": "Apps agentiques dans le Hub",
        "stat_builder_label": "Pour créer la vôtre avec Builder",
        "stat_runtime_label": "Auto-hébergé, vos données"
    },
    "es": {
        "welcome_eyebrow": "BIENVENIDO",
        "welcome_title_long": "El runtime para\napps agénticas.",
        "welcome_subtitle_long": "Instala cientos de agentes desde el Hub. Crea los tuyos en minutos con Digitorn Builder. Un solo runtime premium para todo.",
        "welcome_cta": "Empezar",
        "stat_hub_label": "Apps agénticas en el Hub",
        "stat_builder_label": "Para crear la tuya con Builder",
        "stat_runtime_label": "Autoalojado, tus datos"
    },
    "de": {
        "welcome_eyebrow": "WILLKOMMEN",
        "welcome_title_long": "Die Runtime für\nAgenten-Apps.",
        "welcome_subtitle_long": "Installiere hunderte Agenten aus dem Hub. Baue deine eigenen in Minuten mit Digitorn Builder. Eine Premium-Runtime für alles.",
        "welcome_cta": "Loslegen",
        "stat_hub_label": "Agenten-Apps im Hub",
        "stat_builder_label": "Um deine mit Builder zu bauen",
        "stat_runtime_label": "Selbst gehostet, deine Daten"
    },
    "pt": {
        "welcome_eyebrow": "BEM-VINDO",
        "welcome_title_long": "O runtime para\napps agênticos.",
        "welcome_subtitle_long": "Instale centenas de agentes do Hub. Crie os seus em minutos com Digitorn Builder. Um runtime premium para tudo.",
        "welcome_cta": "Começar",
        "stat_hub_label": "Apps agênticos no Hub",
        "stat_builder_label": "Para criar o seu com Builder",
        "stat_runtime_label": "Auto-hospedado, seus dados"
    },
    "it": {
        "welcome_eyebrow": "BENVENUTO",
        "welcome_title_long": "Il runtime per\napp agentiche.",
        "welcome_subtitle_long": "Installa centinaia di agenti dall'Hub. Crea i tuoi in pochi minuti con Digitorn Builder. Un solo runtime premium per tutto.",
        "welcome_cta": "Inizia",
        "stat_hub_label": "App agentiche nell'Hub",
        "stat_builder_label": "Per crearne una con Builder",
        "stat_runtime_label": "Auto-ospitato, i tuoi dati"
    }
}

for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('onboarding', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
