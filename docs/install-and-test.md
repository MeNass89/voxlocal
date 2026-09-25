# Installer et tester le prototype

L’export source complet est [`VoxLocal-Product-Source-2026-09-25.zip`](../VoxLocal-Product-Source-2026-09-25.zip)
(SHA-256 `9b70a4a162dccd19bbac23b053a86ed8005be7e1a3b610e7add8b48f8c3c15af`).
L’archive exclut les caches Xcode/SwiftPM, les données utilisateur Xcode, les sorties générées et les autres archives. Les empreintes de tous les artefacts sont dans
[`RELEASE-CHECKSUMS-2026-09-25.txt`](../RELEASE-CHECKSUMS-2026-09-25.txt).

## Mac

`VoxLocal-Agent-2026-09-24.dmg` à la racine est le nouveau build macOS
reconstruit depuis l’export complet et régénéré le 25 septembre après le
durcissement du runtime Mac. Il contient l’application arm64 et les sources
durcies de l’agent dans `Contents/Resources/Agent/`; son lanceur exige
Python 3.11+ mais aucun token ni interpréteur n’est embarqué. Son SHA-256
actuel est `d9400e33b7fc6acccfced009f898f2b4e79700da2e15259d1c3ef90dedfcf2c4`.

`VoxLocal.dmg` reste l’image macOS originale fournie avec le
prototype (VoxLocal 2.0.0, binaire Intel x86_64, macOS 13+). Elle contient
`VoxLocal.app` et peut être ouverte par double-clic, puis l’application glissée
dans Applications. Sa signature actuelle est ad hoc : si Gatekeeper la bloque,
utiliser clic droit → Ouvrir, puis **Ouvrir**, ou **Réglages Système →
Confidentialité et sécurité → Ouvrir quand même**. Sur Apple Silicon, macOS peut
demander Rosetta. Elle n’est pas le build durci. L’implémentation Python de
l’agent est dans le nouveau DMG ; le serveur de compatibilité reste sous
`server/voxlocal_server.py` et peut tourner sur macOS ou Windows.

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
TEAM_ID=TON_TEAM_ID ./scripts/build-ios.sh
```

Le projet a été compilé sans signature avec Xcode 27.0. La machine voit
l’iPhone apparié (iPhone16,1) comme appareil apparié et le runtime Simulator
iOS 27 est installé. La sélection de la Personal Team, l’activation du mode
Développeur et la confiance sur l’iPhone restent des étapes Xcode locales.

Le projet contient actuellement l'identifiant `com.voxlocal.remotescribe.portable`
et laisse la Team vide pour que Xcode utilise ton compte. Ouvre **Signing &
Capabilities**, choisis ta Team personnelle, ou lance
`TEAM_ID=TON_TEAM_ID ./scripts/build-ios.sh`. Pour un test sur iPhone il
faut seulement un appareil enregistré et le mode développeur ; pour TestFlight
ou MDM il faut le compte Apple Developer de l'hôpital et son profil de
distribution. Je n'ai besoin d'aucun certificat privé ou mot de passe : tu les
gardes dans Xcode/Trousseau et tu ne me les envoies pas.

Pour le mock TCP local, lancer le serveur avec `--mock --insecure-test-only` et
désactiver TLS dans le panneau de connexion de l’app. Ce mode est réservé aux
données synthétiques.

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

Le paquet [`VoxLocal-Windows-Runtime-2026-09-25.zip`](../VoxLocal-Windows-Runtime-2026-09-25.zip)
contient l’agent, le serveur TLS de référence et les scripts
`windows/install-runtime.ps1` / `uninstall-runtime.ps1`. Son SHA-256 est
`22792f90624e04d0eca5b7ff38adbe236c167c19d4157a69016a455093dbb123`. La
procédure et les limites sont dans [`windows-deployment.md`](windows-deployment.md) ;
la validation PowerShell finale doit être effectuée sur Windows.

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
