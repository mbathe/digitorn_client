"""Inbox extras."""
import json
packs = {
    "en": {"archive": "Archive"},
    "fr": {"archive": "Archiver"},
    "es": {"archive": "Archivar"},
    "de": {"archive": "Archivieren"},
    "pt": {"archive": "Arquivar"},
    "it": {"archive": "Archivia"}
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('inbox', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
