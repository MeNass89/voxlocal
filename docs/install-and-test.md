# Installer et tester le prototype

Le dépôt est la seule source : les artefacts (DMG, `.ipa`, archives) ne sont pas
versionnés et se reconstruisent à partir de lui. Versions actuelles :
VoxLocal.app 2.3.0 (build 5), Remote Scribe iOS 1.3 (build 4).

## Mac

VoxLocal exige macOS 15 ou plus récent sur Apple Silicon. Construire l’app et
le DMG depuis le dépôt (détails dans [`mac-build.md`](mac-build.md)) :

```bash
git submodule update --init
(cd mac/VoxLocal && ./build-runtimes.sh)
./scripts/build-macos.sh
codesign --verify --deep --strict /tmp/voxlocal-desktop-app/VoxLocal.app
```

Le DMG contient l’application arm64 et les sources de l’agent dans
`Contents/Resources/Agent/` ; son lanceur exige Python 3.11 ou plus récent, et
aucun token ni interpréteur n’est embarqué. La signature est ad hoc : si
Gatekeeper bloque l’app, utiliser clic droit → Ouvrir, puis **Ouvrir**, ou
**Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.

Au premier lancement, accorder Microphone et Accessibilité (pour coller le
texte), puis installer les modèles depuis Réglages › Intelligence artificielle.
L’écran **iPhone** affiche le QR code d’appairage, le code et l’empreinte TLS.
Le serveur de compatibilité Python reste sous `server/voxlocal_server.py` et peut
tourner sur macOS ou Windows.

## iPhone / iPad

Aucun `.ipa` signé n’est livré. La source Xcode canonique est
`ios/RemoteScribePortable.xcodeproj` ; le client Core durci qu’elle compile est
dans `ios/Core/Sources`. Pour produire une app testable :

1. Installer la version complète de Xcode, puis ouvrir le projet.
2. Dans **Signing & Capabilities**, sélectionner la Team Apple et remplacer le
   Bundle Identifier si nécessaire.
3. Brancher l’iPhone/iPad, l’ajouter comme destination, activer le mode
   développeur et accepter les permissions Réseau local + Microphone.
4. Cliquer **Run**. Un compte Apple gratuit permet un profil de développement
   temporaire ; un compte Apple Developer payant permet une signature durable,
   TestFlight ou une distribution MDM.

Le projet a été compilé ici avec Xcode 27.0 sans signature. Aucun `.ipa` signé
n’est livré : la signature appareil se fait dans Xcode avec la Personal Team.

Le build reproductible est préparé par
[`scripts/build-ios.sh`](../scripts/build-ios.sh) :

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
./scripts/build-ios.sh
```

Le cache peut rester hors iCloud et la destination peut viser l’iPhone
physique :

```bash
VOXLOCAL_IOS_DERIVED_DATA_PATH=/tmp/voxlocal-ios-derived \
DESTINATION='platform=iOS,id=<IPHONE_UDID>' \
TEAM_ID=VOTRE_TEAM_ID ./scripts/build-ios.sh
```

Le projet a été compilé sans signature avec Xcode 27.0. La machine voit
l’iPhone apparié (iPhone16,1) comme appareil apparié et le runtime Simulator
iOS 27 est installé. La sélection de la Personal Team, l’activation du mode
Développeur et la confiance sur l’iPhone restent des étapes Xcode locales.

Le projet contient l’identifiant `com.voxlocal.remotescribe.portable` et laisse
la Team vide pour que Xcode utilise votre compte. Ouvrez **Signing &
Capabilities** et choisissez votre Team personnelle, ou lancez
`TEAM_ID=VOTRE_TEAM_ID ./scripts/build-ios.sh`. Pour un test sur iPhone, il
faut seulement un appareil enregistré et le mode développeur ; pour TestFlight
ou MDM, il faut le compte Apple Developer de l’hôpital et son profil de
distribution. Aucun certificat privé ni mot de passe n’a à quitter votre Xcode
ou votre trousseau.

Pour le mock TCP local, lancer le serveur avec `--mock --insecure-test-only` et
désactiver TLS dans le panneau de connexion de l’app. L’app n’accepte le mode
non chiffré que vers `localhost`, donc depuis le simulateur. Ce mode est réservé
aux données synthétiques.

Avec VoxLocal sur le Mac, scanner le QR code de l’écran **iPhone**, ou saisir
l’adresse du Mac et le code, puis comparer l’empreinte affichée par l’iPhone à
celle du Mac avant de faire confiance. Le parcours de démonstration est dans
[`demo-runbook.md`](demo-runbook.md).

## GPU loué

Aucun fournisseur GPU, URL ou token n’est présent dans ce dossier. Le flux
prévu est : iPhone → hôte Windows/macOS → endpoint GPU privé HTTPS compatible
OpenAI. Le serveur utilise :

- `POST /v1/audio/transcriptions` pour Whisper ;
- optionnellement `POST /v1/chat/completions` pour la reformulation ;
- `VOXLOCAL_GPU_URL`, `VOXLOCAL_GPU_TOKEN`, et éventuellement
  `VOXLOCAL_LLM_URL` / `VOXLOCAL_LLM_TOKEN` pour la configuration.

Exemple Windows : l’installateur génère l’identité TLS dans `-TlsDir` et
enregistre la tâche serveur (lancée à l’ouverture de session) ; pour démarrer à
la main, `run-windows.ps1` lit les secrets dans l’environnement :

```powershell
.\windows\install-runtime.ps1 `
  -RegisterScheduledTask -ScheduledTask Server `
  -BindAddress 10.42.5.20 `
  -TlsDir C:\ProgramData\VoxLocal\tls
$env:VOXLOCAL_PAIRING_CODE = "secret-de-pilote-12-caracteres"
$env:VOXLOCAL_GPU_URL = "https://gpu.interne.example"
$env:VOXLOCAL_GPU_TOKEN = "..."
.\server\run-windows.ps1 `
  -BindAddress 10.42.5.20 `
  -TlsCert C:\ProgramData\VoxLocal\tls\server.cert.pem `
  -TlsKey C:\ProgramData\VoxLocal\tls\server.key.pem
```

L’installateur affiche l’empreinte SHA-256 du certificat ; la comparer avec
celle que l’iPhone montre à la première connexion. Sur macOS ou Linux,
`scripts/make-tls-identity.sh <dossier>` produit la même identité. Détails dans
[`windows-deployment.md`](windows-deployment.md).

Le fournisseur doit fournir la région de traitement, le DPA, la garantie ZDR,
la désactivation de l’entraînement et la politique de journaux avant toute
donnée patient. Le code ne loue pas automatiquement une machine GPU.

## Paquet Windows

Le runtime Windows s’installe depuis une copie du dépôt avec
`windows/install-runtime.ps1` et se retire avec `uninstall-runtime.ps1`. La
procédure et les limites sont dans [`windows-deployment.md`](windows-deployment.md) ;
la CI exécute l’installation et la désinstallation sur `windows-latest`, la
validation sur un poste réel du parc reste à faire.

## CLI et API pour les agents

Le runtime local livrable est documenté dans [`agent-api.md`](agent-api.md).
Avec Python 3.11 ou plus récent, installer le projet en editable puis démarrer
le mock avec un token fourni par le coffre du poste :

```powershell
python -m pip install -e .
$env:VOXLOCAL_AGENT_TOKEN = "un-token-local-d-au-moins-16-caracteres"
python -m agent.voxlocal_agent_api serve --mock
python -m agent.voxlocal_agent_api status --pretty
```

Pour le déploiement, le service reçoit séparément `VOXLOCAL_GPU_URL`,
`VOXLOCAL_CLEAN_URL` et `VOXLOCAL_LLM_URL` ainsi que leurs tokens et modèles.
Le poste ne reçoit jamais le contenu de `/workspace/voxlocal/api-token` ; ce
fichier reste lu à l'intérieur du Pod RunPod par son bootstrap.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) tourne à chaque push
sur `main` et sur chaque pull request. Un nouveau push sur la même branche
annule le run en cours. Trois jobs :

- **`python-linux`** (`ubuntu-latest`, Python 3.11 et 3.12) : les trois suites
  `unittest` (`windows/`, `tests/`, `agent/`) et `py_compile` des modules
  Python. Les tests Swift (`tests/test_swift_core.py`,
  `tests/test_real_host_interop.py`) se sautent eux-mêmes hors macOS.
- **`python-windows`** (`windows-latest`, Python 3.12) : les mêmes suites,
  puis l’analyse syntaxique de chaque `*.ps1` par PowerShell 7 et par
  Windows PowerShell 5.1. Ensuite un vrai passage de l’installateur :
  `install-runtime.ps1 -InstallRoot $env:RUNNER_TEMP\voxlocal -MockTask`
  (sans `-RegisterScheduledTask`, donc aucune tâche planifiée), vérification
  du manifeste et de l’import `agent.voxlocal_agent_api` depuis le venv créé,
  puis `uninstall-runtime.ps1 -Confirm:$false` et vérification que le dossier
  a disparu. Enfin `new-tls-identity.ps1` génère une identité dans
  `$env:RUNNER_TEMP\tls` avec l’`openssl.exe` de Git for Windows ; le job
  vérifie les deux fichiers et que l’empreinte affichée égale le SHA-256 du
  certificat DER.
- **`macos`** (`macos-26`, Xcode 26.6, sans les sous-modules `Vendor/`) :
  `swift test` du paquet `RemoteScribe`, `swift build -c release --product
  VoxLocal`, les trois suites Python (c’est ici que tournent vraiment la
  régression du Core Swift, la fixture TLS avec épinglage et l’interop contre
  le vrai `RemoteScribeHost`), puis `CODE_SIGNING_ALLOWED=NO
  ./scripts/build-ios.sh` (build `iphoneos` non signé). Les dossiers `.build`
  SwiftPM sont mis en cache, clé = empreinte des deux `Package.swift`. Un
  premier run à froid peut prendre 15 minutes ; la limite est 45 minutes.

Pour reproduire le job macOS en local :

```bash
(cd RemoteScribe && swift test)
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
for suite in windows tests agent; do python3 -m unittest discover -s "$suite" -p 'test_*.py' -v; done
CODE_SIGNING_ALLOWED=NO ./scripts/build-ios.sh
```

Sans `TEAM_ID`, `scripts/build-ios.sh` compile la cible
`RemoteScribePortable` pour le SDK `iphoneos`, sans schéma ni destination ;
avec `TEAM_ID`, il garde le build par schéma et honore `DESTINATION`.
