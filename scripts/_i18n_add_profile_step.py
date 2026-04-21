"""Profile step keys."""
import json
packs = {
    "en": {
        "step_01": "STEP 01",
        "profile_title_long": "Let's get you set up.",
        "profile_subtitle_long": "A bit about you — we use this to tailor your workspace and suggest the right starter apps.",
        "profile_display_name": "Display name",
        "profile_name_placeholder": "How should we call you?",
        "profile_what_describes_you": "WHAT BEST DESCRIBES YOU",
        "role_developer_desc": "Build software with AI.",
        "role_analyst_desc": "Explore data and find insights.",
        "role_operator_desc": "Automate ops and workflows.",
        "role_researcher_desc": "Search, synthesize, write.",
        "role_other_title": "Something else",
        "role_other_desc": "Explore at your own pace."
    },
    "fr": {
        "step_01": "ÉTAPE 01",
        "profile_title_long": "Configurons votre espace.",
        "profile_subtitle_long": "Un peu sur vous — nous l'utilisons pour adapter votre espace et suggérer les bonnes apps de départ.",
        "profile_display_name": "Nom affiché",
        "profile_name_placeholder": "Comment vous appeler ?",
        "profile_what_describes_you": "CE QUI VOUS DÉCRIT LE MIEUX",
        "role_developer_desc": "Construire des logiciels avec l'IA.",
        "role_analyst_desc": "Explorer les données et trouver des insights.",
        "role_operator_desc": "Automatiser les opérations et workflows.",
        "role_researcher_desc": "Rechercher, synthétiser, écrire.",
        "role_other_title": "Autre chose",
        "role_other_desc": "Explorer à votre rythme."
    },
    "es": {
        "step_01": "PASO 01",
        "profile_title_long": "Vamos a configurarte.",
        "profile_subtitle_long": "Un poco sobre ti — lo usamos para adaptar tu espacio y sugerir las apps iniciales adecuadas.",
        "profile_display_name": "Nombre visible",
        "profile_name_placeholder": "¿Cómo te llamamos?",
        "profile_what_describes_you": "LO QUE MEJOR TE DESCRIBE",
        "role_developer_desc": "Construye software con IA.",
        "role_analyst_desc": "Explora datos y encuentra insights.",
        "role_operator_desc": "Automatiza ops y flujos.",
        "role_researcher_desc": "Busca, sintetiza, escribe.",
        "role_other_title": "Algo más",
        "role_other_desc": "Explora a tu propio ritmo."
    },
    "de": {
        "step_01": "SCHRITT 01",
        "profile_title_long": "Lass uns dich einrichten.",
        "profile_subtitle_long": "Ein bisschen über dich — damit wir deinen Workspace anpassen und die passenden Starter-Apps vorschlagen.",
        "profile_display_name": "Anzeigename",
        "profile_name_placeholder": "Wie sollen wir dich nennen?",
        "profile_what_describes_you": "WAS BESCHREIBT DICH AM BESTEN",
        "role_developer_desc": "Baue Software mit KI.",
        "role_analyst_desc": "Erkunde Daten und finde Erkenntnisse.",
        "role_operator_desc": "Automatisiere Ops und Workflows.",
        "role_researcher_desc": "Suchen, zusammenfassen, schreiben.",
        "role_other_title": "Etwas anderes",
        "role_other_desc": "Erkunde in deinem eigenen Tempo."
    },
    "pt": {
        "step_01": "PASSO 01",
        "profile_title_long": "Vamos configurar você.",
        "profile_subtitle_long": "Um pouco sobre você — usamos isso para personalizar seu workspace e sugerir as apps iniciais certas.",
        "profile_display_name": "Nome exibido",
        "profile_name_placeholder": "Como devemos te chamar?",
        "profile_what_describes_you": "O QUE MELHOR TE DESCREVE",
        "role_developer_desc": "Construa software com IA.",
        "role_analyst_desc": "Explore dados e encontre insights.",
        "role_operator_desc": "Automatize ops e workflows.",
        "role_researcher_desc": "Pesquise, sintetize, escreva.",
        "role_other_title": "Outra coisa",
        "role_other_desc": "Explore no seu próprio ritmo."
    },
    "it": {
        "step_01": "PASSO 01",
        "profile_title_long": "Configuriamoti.",
        "profile_subtitle_long": "Un po' su di te — lo usiamo per personalizzare il tuo workspace e suggerire le app iniziali giuste.",
        "profile_display_name": "Nome visualizzato",
        "profile_name_placeholder": "Come dovremmo chiamarti?",
        "profile_what_describes_you": "COSA TI DESCRIVE MEGLIO",
        "role_developer_desc": "Costruisci software con IA.",
        "role_analyst_desc": "Esplora dati e trova insight.",
        "role_operator_desc": "Automatizza operazioni e workflow.",
        "role_researcher_desc": "Cerca, sintetizza, scrivi.",
        "role_other_title": "Qualcos'altro",
        "role_other_desc": "Esplora al tuo ritmo."
    }
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('onboarding', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
