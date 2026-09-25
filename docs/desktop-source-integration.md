# Intégration de la source desktop

L’export complet conservé dans `desktop-source/VoxLocal-Source-Complet/` garde
`VoxLocal/` et `RemoteScribe/` côte à côte. `VoxLocal/Package.swift` référence
la bibliothèque locale `../RemoteScribe`; déplacer VoxLocal seul casse donc le
build.

VoxLocal macOS contient déjà le serveur RemoteScribeCore et ses adaptateurs
Whisper/LLM locaux. L’API agent Python (`agent/voxlocal_agent_api.py`) est un
contrat HTTP loopback séparé. Elle ne doit pas être présentée comme le serveur
Swift ni démarrée silencieusement par l’interface.

## DMG vérifiable

Depuis la racine du dépôt (le wrapper place automatiquement le bundle de
travail et le staging dans `/tmp`, puis écrit le DMG à la racine) :

```bash
./scripts/build-macos.sh
```

Pour éviter les caches Swift dans iCloud, donner un scratch path local :

```bash
VOXLOCAL_SWIFT_BUILD_PATH=/tmp/voxlocal-swift-build ./scripts/build-macos.sh
```

Quand la source est dans iCloud Drive, placer aussi le bundle de travail hors
du dossier synchronisé afin que Finder ne réinjecte pas ses attributs pendant
la signature :

```bash
VOXLOCAL_APP_DIR=/tmp/voxlocal-desktop-app/VoxLocal.app \
VOXLOCAL_SWIFT_BUILD_PATH=/tmp/voxlocal-swift-build \
VOXLOCAL_DMG_STAGING_PATH=/tmp/voxlocal-desktop-dmg \
VOXLOCAL_DMG_PATH=/chemin/de/sortie/VoxLocal-Agent-2026-09-24.dmg \
./scripts/build-macos.sh
```

Le script appelle `VoxLocal/package-dmg.sh`, puis `build.sh`. Le bundle contient
les sources `Resources/Agent/agent`, la documentation, `pyproject.toml` et un
lanceur `Resources/Agent/bin/voxlocal-agent`. Le lanceur exige Python 3.11 ou
plus récent, vérifie sa version avant exécution et renvoie une erreur claire
si Python manque. Il n’embarque pas Python, de modèle, de token ou de secret.

Le chemin du code agent peut être fourni pour un export déplacé :

```bash
VOXLOCAL_AGENT_SOURCE_DIR=/chemin/vers/agent \
VOXLOCAL_AGENT_DOC_SOURCE_DIR=/chemin/vers/docs \
  ./scripts/build-macos.sh
```

Les dossiers `VoxLocal/.build` et `VoxLocal/dist` sont des sorties générées et
ne font pas partie de la source à distribuer ; le wrapper les remplace par des
chemins de travail hors iCloud. Cela évite de signer un bundle Finder obsolète
ou de transporter des caches Swift dans un export source.

Les runtimes Whisper et Llama livrés par l’export sont actuellement x86_64;
sur Apple Silicon, Rosetta est nécessaire jusqu’à une reconstruction native.
Le code est signé ad hoc pour les essais locaux et n’est pas notarisé.
L’export iCloud peut réappliquer `com.apple.FinderInfo` après signature;
les scripts nettoient ces attributs avant signature et avant la création du DMG.

## État de l’agent

Le mode `--mock` est testable sans réseau et ne produit que du texte
synthétique. Les URL GPU, nettoyage et LLM doivent être HTTPS et fournies par
l’environnement du service. Aucun endpoint RunPod n’est codé ou testé ici.
Le service reste loopback-only et authentifié par `VOXLOCAL_AGENT_TOKEN`;
l’utilisateur doit le démarrer explicitement :

```bash
VOXLOCAL_AGENT_TOKEN='un-secret-local-d-au-moins-16-caracteres' \
  VoxLocal.app/Contents/Resources/Agent/bin/voxlocal-agent serve --mock
```

Le DMG ne prétend donc pas fournir un interpréteur Python autonome. La preuve
de packaging est la présence du lanceur et de son code source dans le bundle;
la preuve de fonctionnement de l’API reste `python3 -m unittest agent/test_agent_api.py`
avec Python 3.11+.
