"""Admin scaffold keys."""
import json
packs = {
    "en": {"just_now": "just now", "ago_m": "{n}m", "ago_h": "{n}h", "ago_d": "{n}d"},
    "fr": {"just_now": "à l'instant", "ago_m": "{n}min", "ago_h": "{n}h", "ago_d": "{n}j"},
    "es": {"just_now": "ahora", "ago_m": "{n}m", "ago_h": "{n}h", "ago_d": "{n}d"},
    "de": {"just_now": "gerade eben", "ago_m": "{n}m", "ago_h": "{n}h", "ago_d": "{n}T"},
    "pt": {"just_now": "agora mesmo", "ago_m": "{n}m", "ago_h": "{n}h", "ago_d": "{n}d"},
    "it": {"just_now": "adesso", "ago_m": "{n}m", "ago_h": "{n}h", "ago_d": "{n}g"}
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('admin', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
