"""Add slash command labels and descriptions."""
import json
ROOT = 'C:/Users/ASUS/Documents/digitorn_client/assets/translations/'
LANGS = ['en', 'fr', 'es', 'de', 'pt', 'it']

SLASH = {
    # label, description
    'explain': (
        {'en': 'Explain', 'fr': 'Expliquer', 'es': 'Explicar', 'de': 'Erklären', 'pt': 'Explicar', 'it': 'Spiega'},
        {'en': 'Explain the code or concept', 'fr': 'Expliquer le code ou le concept', 'es': 'Explicar el código o concepto',
         'de': 'Code oder Konzept erklären', 'pt': 'Explicar o código ou conceito', 'it': 'Spiega il codice o il concetto'},
    ),
    'summarize': (
        {'en': 'Summarize', 'fr': 'Résumer', 'es': 'Resumir', 'de': 'Zusammenfassen', 'pt': 'Resumir', 'it': 'Riassumi'},
        {'en': 'Summarize what was done', 'fr': 'Résumer ce qui a été fait', 'es': 'Resumir lo que se hizo',
         'de': 'Zusammenfassen, was getan wurde', 'pt': 'Resumir o que foi feito', 'it': 'Riassumi ciò che è stato fatto'},
    ),
    'continue': (
        {'en': 'Continue', 'fr': 'Continuer', 'es': 'Continuar', 'de': 'Fortsetzen', 'pt': 'Continuar', 'it': 'Continua'},
        {'en': 'Continue the current task', 'fr': 'Continuer la tâche actuelle', 'es': 'Continuar la tarea actual',
         'de': 'Aktuelle Aufgabe fortsetzen', 'pt': 'Continuar a tarefa atual', 'it': 'Continua l’attività corrente'},
    ),
    'plan': (
        {'en': 'Plan', 'fr': 'Planifier', 'es': 'Planificar', 'de': 'Planen', 'pt': 'Planejar', 'it': 'Pianifica'},
        {'en': 'Create a plan before acting', 'fr': 'Créer un plan avant d’agir', 'es': 'Crear un plan antes de actuar',
         'de': 'Vor dem Handeln einen Plan erstellen', 'pt': 'Criar um plano antes de agir', 'it': 'Crea un piano prima di agire'},
    ),
    'review': (
        {'en': 'Review', 'fr': 'Réviser', 'es': 'Revisar', 'de': 'Überprüfen', 'pt': 'Revisar', 'it': 'Rivedi'},
        {'en': 'Review the recent changes', 'fr': 'Réviser les modifications récentes', 'es': 'Revisar los cambios recientes',
         'de': 'Aktuelle Änderungen überprüfen', 'pt': 'Revisar as alterações recentes', 'it': 'Rivedi le modifiche recenti'},
    ),
    'read': (
        {'en': 'Read', 'fr': 'Lire', 'es': 'Leer', 'de': 'Lesen', 'pt': 'Ler', 'it': 'Leggi'},
        {'en': 'Read a file', 'fr': 'Lire un fichier', 'es': 'Leer un archivo', 'de': 'Datei lesen', 'pt': 'Ler um arquivo', 'it': 'Leggi un file'},
    ),
    'edit': (
        {'en': 'Edit', 'fr': 'Modifier', 'es': 'Editar', 'de': 'Bearbeiten', 'pt': 'Editar', 'it': 'Modifica'},
        {'en': 'Edit a file', 'fr': 'Modifier un fichier', 'es': 'Editar un archivo', 'de': 'Datei bearbeiten', 'pt': 'Editar um arquivo', 'it': 'Modifica un file'},
    ),
    'find': (
        {'en': 'Find', 'fr': 'Trouver', 'es': 'Buscar', 'de': 'Suchen', 'pt': 'Localizar', 'it': 'Trova'},
        {'en': 'Search for files', 'fr': 'Rechercher des fichiers', 'es': 'Buscar archivos', 'de': 'Nach Dateien suchen',
         'pt': 'Pesquisar arquivos', 'it': 'Cerca file'},
    ),
    'run': (
        {'en': 'Run', 'fr': 'Exécuter', 'es': 'Ejecutar', 'de': 'Ausführen', 'pt': 'Executar', 'it': 'Esegui'},
        {'en': 'Run a shell command', 'fr': 'Exécuter une commande shell', 'es': 'Ejecutar un comando shell',
         'de': 'Shell-Befehl ausführen', 'pt': 'Executar um comando shell', 'it': 'Esegui un comando shell'},
    ),
    'test': (
        {'en': 'Test', 'fr': 'Tester', 'es': 'Probar', 'de': 'Testen', 'pt': 'Testar', 'it': 'Testa'},
        {'en': 'Run the test suite', 'fr': 'Lancer la suite de tests', 'es': 'Ejecutar la suite de pruebas',
         'de': 'Testsuite ausführen', 'pt': 'Executar a suite de testes', 'it': 'Esegui la suite di test'},
    ),
    'install': (
        {'en': 'Install', 'fr': 'Installer', 'es': 'Instalar', 'de': 'Installieren', 'pt': 'Instalar', 'it': 'Installa'},
        {'en': 'Install dependencies', 'fr': 'Installer les dépendances', 'es': 'Instalar dependencias',
         'de': 'Abhängigkeiten installieren', 'pt': 'Instalar dependências', 'it': 'Installa le dipendenze'},
    ),
    'commit': (
        {'en': 'Commit', 'fr': 'Commit', 'es': 'Commit', 'de': 'Commit', 'pt': 'Commit', 'it': 'Commit'},
        {'en': 'Create a git commit', 'fr': 'Créer un commit git', 'es': 'Crear un commit de git',
         'de': 'Einen Git-Commit erstellen', 'pt': 'Criar um commit do git', 'it': 'Crea un commit git'},
    ),
    'diff': (
        {'en': 'Diff', 'fr': 'Diff', 'es': 'Diff', 'de': 'Diff', 'pt': 'Diff', 'it': 'Diff'},
        {'en': 'Show git diff', 'fr': 'Afficher le diff git', 'es': 'Mostrar diff de git',
         'de': 'Git-Diff anzeigen', 'pt': 'Mostrar diff do git', 'it': 'Mostra diff git'},
    ),
    'pr': (
        {'en': 'PR', 'fr': 'PR', 'es': 'PR', 'de': 'PR', 'pt': 'PR', 'it': 'PR'},
        {'en': 'Create a pull request', 'fr': 'Créer une pull request', 'es': 'Crear un pull request',
         'de': 'Pull Request erstellen', 'pt': 'Criar uma pull request', 'it': 'Crea una pull request'},
    ),
    'search': (
        {'en': 'Search', 'fr': 'Rechercher', 'es': 'Buscar', 'de': 'Suchen', 'pt': 'Pesquisar', 'it': 'Cerca'},
        {'en': 'Search the web', 'fr': 'Rechercher sur le web', 'es': 'Buscar en la web',
         'de': 'Im Web suchen', 'pt': 'Pesquisar na web', 'it': 'Cerca nel web'},
    ),
    'fetch': (
        {'en': 'Fetch', 'fr': 'Récupérer', 'es': 'Obtener', 'de': 'Abrufen', 'pt': 'Obter', 'it': 'Recupera'},
        {'en': 'Fetch a URL', 'fr': 'Récupérer une URL', 'es': 'Obtener una URL',
         'de': 'URL abrufen', 'pt': 'Obter uma URL', 'it': 'Recupera un URL'},
    ),
    'goal': (
        {'en': 'Goal', 'fr': 'Objectif', 'es': 'Objetivo', 'de': 'Ziel', 'pt': 'Meta', 'it': 'Obiettivo'},
        {'en': 'Set a project goal', 'fr': 'Définir un objectif de projet', 'es': 'Establecer un objetivo del proyecto',
         'de': 'Projektziel festlegen', 'pt': 'Definir uma meta do projeto', 'it': 'Imposta un obiettivo del progetto'},
    ),
    'todo': (
        {'en': 'Todo', 'fr': 'Tâche', 'es': 'Tarea', 'de': 'Aufgabe', 'pt': 'Tarefa', 'it': 'Attività'},
        {'en': 'Add a task to the list', 'fr': 'Ajouter une tâche à la liste', 'es': 'Añadir una tarea a la lista',
         'de': 'Aufgabe zur Liste hinzufügen', 'pt': 'Adicionar uma tarefa à lista', 'it': 'Aggiungi un’attività alla lista'},
    ),
    'query': (
        {'en': 'Query', 'fr': 'Requête', 'es': 'Consulta', 'de': 'Abfrage', 'pt': 'Consulta', 'it': 'Query'},
        {'en': 'Run a database query', 'fr': 'Exécuter une requête de base de données', 'es': 'Ejecutar una consulta a la base de datos',
         'de': 'Datenbankabfrage ausführen', 'pt': 'Executar uma consulta ao banco de dados', 'it': 'Esegui una query al database'},
    ),
}

for lang in LANGS:
    path = ROOT + lang + '.json'
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    ns = data.setdefault('chat_slash', {})
    for key, (labs, descs) in SLASH.items():
        ns[key + '_label'] = labs[lang]
        ns[key + '_desc'] = descs[lang]
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
print('done')
