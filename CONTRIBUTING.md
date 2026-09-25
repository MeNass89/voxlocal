# Contribuer

Le code est publié pour relecture et audit (voir [`LICENSE`](LICENSE)). Ce fichier décrit l’arborescence, les règles non négociables et les vérifications à lancer avant tout commit.

## Arborescence

| Dossier | Contenu |
|---|---|
| `ios/` | Client iPhone/iPad : projet Xcode `RemoteScribePortable.xcodeproj`, UI SwiftUI, copie durcie du client Core dans `ios/Core/Sources`. |
| `RemoteScribe/` | Paquet Swift `RemoteScribeCore` livré : protocole, serveur, backends, hôte CLI, app de barre des menus, client web. |
| `mac/VoxLocal/` | App macOS VoxLocal (paquet Swift) ; `Vendor/src/*` sont des sous-modules (whisper.cpp, llama.cpp), `Vendor/bin/` est ignoré par git. |
| `server/` | Hôte Python de référence (`voxlocal_server.py`), TLS 1.3, Windows/macOS. |
| `agent/` | API loopback et CLI JSON pour les harness d’agents. |
| `windows/` | Codec Python v1, hôte de compatibilité réservé aux tests, scripts d’installation PowerShell. |
| `cloud/runpod/` | Bootstrap et benchmark synthétique du runtime GPU RunPod. |
| `tests/` | Tests Python du serveur, du runtime RunPod et de régression du Core Swift. |
| `scripts/` | Builds iOS et macOS reproductibles. |
| `docs/` | Protocole, sécurité, déploiement, revues et matrice de sortie. |
| `website/` | Site vitrine (hors revue de code). |

## Règles

- **Le Core Swift livré est la source de vérité du contrat wire** : `RemoteScribe/Core/Sources/{RemoteProtocol,FrameCodec,RemoteClient,SessionHandler,AudioReceiver}.swift`. Le client iOS et les deux hôtes Python doivent s’y conformer octet par octet ; on ne modifie pas le format de trame pour arranger une autre implémentation.
- **Aucune dépendance Python tierce** : bibliothèque standard uniquement, Python ≥ 3.11, tests en `unittest`.
- Aucun secret dans argv, les logs, git ou les messages d’erreur. Aucune donnée clinique dans les tests : PCM synthétique uniquement.

## Vérifications

```bash
python3 -m unittest discover -s windows -p 'test_*.py' -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m unittest discover -s agent -p 'test_*.py' -v
python3 -m py_compile server/voxlocal_server.py windows/*.py agent/*.py cloud/runpod/*.py
(cd RemoteScribe && swift test)
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

Le build `mac/VoxLocal` exige les sous-modules (`git submodule update --init`) et les runtimes natifs (`./build-runtimes.sh`) ; voir [`docs/mac-build.md`](docs/mac-build.md).
