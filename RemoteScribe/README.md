# Remote Scribe

Un protocole réseau commun relie un client portable à un backend choisi sur le Mac.

```text
iPhone / iPad / second Mac
  → PAIR → START_SESSION → AUDIO_CHUNK* → STOP_SESSION
  → RemoteScribeCore
      ├─ VoxLocalBackend (Whisper local ou mock, puis LLM)
      └─ SuperwhisperBackend (import direct du WAV)
```

## Serveur Superwhisper

Quitter VoxLocal ou désactiver son serveur Remote Scribe pour éviter un conflit de port, puis :

```bash
cd RemoteScribe
./run-superwhisper.sh
```

Le bridge publie `_remotescribe._tcp` avec Bonjour sur le port `47365`. À STOP, il finalise le WAV et l’ouvre directement dans `/Applications/superwhisper.app`. Il surveille ensuite le nouvel enregistrement Superwhisper jusqu’à la présence du résultat final.

Un code peut être exigé avec `./run-superwhisper.sh --pairing-code 123456`. L’application iOS permet de le saisir dans ses réglages de connexion.

## Serveur VoxLocal

Le serveur démarre automatiquement avec VoxLocal. L’écran **Remote Scribe** permet de l’arrêter ou de le relancer. Il utilise le modèle Whisper et le mode LLM sélectionnés. En l’absence de modèle Whisper, `MockTranscriptionEngine` valide le flux et conserve le WAV dans l’historique.

## Organisation

- `Core/` : protocole, réseau, sessions, audio et abstractions de backends partagés.
- `MacServer/` : serveur Bonjour/TCP du Mac, bridge Superwhisper et client de diagnostic.
- `PortableClient/` : application SwiftUI iPhone/iPad.
- `WebClient/` : page web privée destinée au microphone de l’iPhone.

## Client iPhone / iPad

Ouvrir `PortableClient/RemoteScribePortable.xcodeproj` avec Xcode, choisir son équipe de signature, brancher l’appareil et lancer. L’app demande les permissions Microphone et Réseau local, détecte le Mac par Bonjour, permet une connexion manuelle de secours et expose le choix du moteur annoncé, START/STOP, les états détaillés et les résultats récents.

## Diagnostics

```bash
swift run RemoteScribeDiagnostics
swift run RemoteScribeHost --backend voxlocal
swift run RemoteScribeTestClient --discover --backend voxlocal
```

Le protocole binaire est versionné. Chaque trame porte le type, l’UUID de session, un numéro de séquence et le payload. Les chunks absents ou hors ordre sont rejetés.

## Limites de la version LAN

- TCP local sans TLS : suffisant pour un Wi-Fi domestique de confiance, pas pour un réseau hospitalier sans ajouter authentification forte et chiffrement.
- Une seule session active par connexion ; plusieurs clients peuvent se connecter simultanément.
- Superwhisper reste une application tierce : le bridge attend son `meta.json`, avec un délai de 240 secondes.
- Le déploiement iOS sur appareil réel exige une équipe de signature Apple sélectionnée dans Xcode.
