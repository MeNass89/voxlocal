# Build macOS (VoxLocal.app)

## Arborescence

`mac/VoxLocal/` (l’app) et `RemoteScribe/` (le paquet `RemoteScribeCore`)
restent côte à côte dans ce dépôt : `mac/VoxLocal/Package.swift` référence la
bibliothèque locale `../../RemoteScribe`. Déplacer `mac/VoxLocal` seul casse
donc le build.

VoxLocal macOS contient déjà le serveur RemoteScribeCore et ses adaptateurs
Whisper/LLM locaux. L’API agent Python (`agent/voxlocal_agent_api.py`) est un
contrat HTTP loopback séparé. Elle ne doit pas être présentée comme le serveur
Swift ni démarrée silencieusement par l’interface.

## Sous-modules et runtimes natifs

`mac/VoxLocal/Vendor/src/whisper.cpp` et `mac/VoxLocal/Vendor/src/llama.cpp`
sont des sous-modules git épinglés sur les instantanés vendorisés
(whisper.cpp `v1.9.3`, llama.cpp `a298422d`). Après un clone :

```bash
git submodule update --init
```

`mac/VoxLocal/Vendor/bin/` (les exécutables `whisper-cli` et `llama-cli`) est
ignoré par git. Le reconstruire nativement demande CMake :

```bash
cd mac/VoxLocal
./build-runtimes.sh
```

## Build et DMG

Build de l’app seule :

```bash
cd mac/VoxLocal
swift build -c release --product VoxLocal
```

DMG vérifiable, depuis la racine du dépôt (le wrapper place le bundle de
travail, le cache Swift et le staging dans `/tmp`, puis écrit le DMG à la
racine) :

```bash
./scripts/build-macos.sh
```

Variables d’environnement lues par `scripts/build-macos.sh` :

| Variable | Défaut |
|---|---|
| `VOXLOCAL_DESKTOP_SOURCE_DIR` | `mac/VoxLocal` |
| `VOXLOCAL_AGENT_SOURCE_DIR` | `agent` |
| `VOXLOCAL_AGENT_DOC_SOURCE_DIR` | `docs` |
| `VOXLOCAL_APP_DIR` | `/tmp/voxlocal-desktop-app/VoxLocal.app` |
| `VOXLOCAL_SWIFT_BUILD_PATH` | `/tmp/voxlocal-desktop-swift` |
| `VOXLOCAL_DMG_STAGING_PATH` | `/tmp/voxlocal-desktop-dmg` |
| `VOXLOCAL_DMG_PATH` | `VoxLocal-Agent-2026-09-24.dmg` à la racine |

Le script appelle `mac/VoxLocal/package-dmg.sh`, puis `build.sh`. Le bundle
contient les sources `Resources/Agent/agent`, la documentation,
`pyproject.toml` et un lanceur `Resources/Agent/bin/voxlocal-agent`. Le
lanceur exige Python 3.11 ou plus récent, vérifie sa version avant exécution
et renvoie une erreur claire si Python manque. Il n’embarque pas Python, de
modèle, de token ou de secret.

Les dossiers `.build`, `dist` et le DMG sont des sorties générées, ignorées
par git. Le code est signé ad hoc pour les essais locaux et n’est pas notarisé.
Si la copie de travail est dans iCloud Drive, garder les chemins de travail
dans `/tmp` (valeurs par défaut) : Finder peut réappliquer
`com.apple.FinderInfo` après signature ; les scripts nettoient ces attributs
avant signature et avant la création du DMG.

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
