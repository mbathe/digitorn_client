"""Extra onboarding keys for wizard_shell + steps."""
import json

packs = {
    "en": {
        "skip_setup": "Skip setup",
        "tap_continue": "Tap Continue to proceed",
        "hint_continue": "continue",
        "hint_back": "back",
        "hint_skip": "skip"
    },
    "fr": {
        "skip_setup": "Passer la configuration",
        "tap_continue": "Appuyez sur Continuer pour avancer",
        "hint_continue": "continuer",
        "hint_back": "retour",
        "hint_skip": "passer"
    },
    "es": {
        "skip_setup": "Omitir configuración",
        "tap_continue": "Toca Continuar para avanzar",
        "hint_continue": "continuar",
        "hint_back": "atrás",
        "hint_skip": "omitir"
    },
    "de": {
        "skip_setup": "Einrichtung überspringen",
        "tap_continue": "Tippe auf Weiter, um fortzufahren",
        "hint_continue": "weiter",
        "hint_back": "zurück",
        "hint_skip": "überspringen"
    },
    "pt": {
        "skip_setup": "Pular configuração",
        "tap_continue": "Toque em Continuar para avançar",
        "hint_continue": "continuar",
        "hint_back": "voltar",
        "hint_skip": "pular"
    },
    "it": {
        "skip_setup": "Salta configurazione",
        "tap_continue": "Tocca Continua per procedere",
        "hint_continue": "continua",
        "hint_back": "indietro",
        "hint_skip": "salta"
    }
}

for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('onboarding', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')

print('done.')
