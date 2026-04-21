"""Palette extra keys."""
import json
packs = {
    "en": {"type_command": "Type a command...", "to_select": "to select", "to_close": "to close"},
    "fr": {"type_command": "Tapez une commande...", "to_select": "pour sélectionner", "to_close": "pour fermer"},
    "es": {"type_command": "Escribe un comando...", "to_select": "para seleccionar", "to_close": "para cerrar"},
    "de": {"type_command": "Befehl eingeben...", "to_select": "zum Auswählen", "to_close": "zum Schließen"},
    "pt": {"type_command": "Digite um comando...", "to_select": "para selecionar", "to_close": "para fechar"},
    "it": {"type_command": "Digita un comando...", "to_select": "per selezionare", "to_close": "per chiudere"}
}
for lang, extras in packs.items():
    path = f'assets/translations/{lang}.json'
    d = json.load(open(path, 'r', encoding='utf-8'))
    d.setdefault('command_palette', {}).update(extras)
    json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print(lang, 'ok')
