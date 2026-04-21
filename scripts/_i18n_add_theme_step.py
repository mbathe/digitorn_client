"""Theme step keys."""
import json
packs = {
    "en": {
        "step_02": "STEP 02",
        "theme_title_long": "Make it yours.",
        "theme_subtitle_long": "Pick a look and a language. Everything here is changeable later under Settings → Appearance.",
        "language": "LANGUAGE",
        "mode": "MODE",
        "palette": "PALETTE",
        "mode_system": "System",
        "mode_light": "Light",
        "mode_dark": "Dark",
        "pick_badge": "PICK"
    },
    "fr": {
        "step_02": "ÉTAPE 02",
        "theme_title_long": "Personnalisez.",
        "theme_subtitle_long": "Choisissez un look et une langue. Tout ici est modifiable plus tard dans Paramètres → Apparence.",
        "language": "LANGUE",
        "mode": "MODE",
        "palette": "PALETTE",
        "mode_system": "Système",
        "mode_light": "Clair",
        "mode_dark": "Sombre",
        "pick_badge": "CHOIX"
    },
    "es": {
        "step_02": "PASO 02",
        "theme_title_long": "Hazlo tuyo.",
        "theme_subtitle_long": "Elige una apariencia y un idioma. Todo esto es modificable después en Ajustes → Apariencia.",
        "language": "IDIOMA",
        "mode": "MODO",
        "palette": "PALETA",
        "mode_system": "Sistema",
        "mode_light": "Claro",
        "mode_dark": "Oscuro",
        "pick_badge": "ELEGIR"
    },
    "de": {
        "step_02": "SCHRITT 02",
        "theme_title_long": "Mach es zu deinem.",
        "theme_subtitle_long": "Wähle ein Aussehen und eine Sprache. Alles ist später unter Einstellungen → Aussehen änderbar.",
        "language": "SPRACHE",
        "mode": "MODUS",
        "palette": "PALETTE",
        "mode_system": "System",
        "mode_light": "Hell",
        "mode_dark": "Dunkel",
        "pick_badge": "WAHL"
    },
    "pt": {
        "step_02": "PASSO 02",
        "theme_title_long": "Deixe à sua cara.",
        "theme_subtitle_long": "Escolha uma aparência e um idioma. Tudo aqui é alterável depois em Configurações → Aparência.",
        "language": "IDIOMA",
        "mode": "MODO",
        "palette": "PALETA",
        "mode_system": "Sistema",
        "mode_light": "Claro",
        "mode_dark": "Escuro",
        "pick_badge": "ESCOLHA"
    },
    "it": {
        "step_02": "PASSO 02",
        "theme_title_long": "Personalizzalo.",
        "theme_subtitle_long": "Scegli un aspetto e una lingua. Tutto qui è modificabile più tardi in Impostazioni → Aspetto.",
        "language": "LINGUA",
        "mode": "MODO",
        "palette": "PALETTE",
        "mode_system": "Sistema",
        "mode_light": "Chiaro",
        "mode_dark": "Scuro",
        "pick_badge": "SCELTA"
    }
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('onboarding', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
