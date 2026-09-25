# VoxLocal / Remote Scribe — prototype hospitalier

Dictée médicale : l’iPhone ou l’iPad capte la voix et l’envoie en PCM 16 kHz, par le protocole Remote Scribe v1 (TCP/TLS), à un poste hôte macOS ou Windows de l’hôpital. L’hôte transcrit en local (whisper.cpp) ou sur un GPU privé HTTPS, sans persistance applicative par défaut côté hôtes Python.
Le code est publié pour relecture et audit de sécurité ; voir [`LICENSE`](LICENSE) et [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Arborescence

| Dossier | Contenu |
|---|---|
| [`ios/`](ios) | Client iPhone/iPad : projet Xcode [`RemoteScribePortable.xcodeproj`](ios/RemoteScribePortable.xcodeproj), UI SwiftUI, capture micro, historique Keychain ; copie durcie du client Core dans [`ios/Core/Sources`](ios/Core/Sources). |
| [`RemoteScribe/`](RemoteScribe) | Paquet Swift `RemoteScribeCore` livré (protocole, serveur, backends, hôte CLI, app de barre des menus, client web). Source de vérité du contrat wire. |
| [`mac/VoxLocal/`](mac/VoxLocal) | App macOS VoxLocal, qui embarque le serveur `RemoteScribeCore` et les moteurs whisper.cpp/llama.cpp (sous-modules dans `Vendor/src`). |
| [`server/`](server) | Hôte Python de référence [`voxlocal_server.py`](server/voxlocal_server.py) : TLS 1.3, quotas, mode mock explicite, GPU OpenAI-compatible HTTPS. |
| [`agent/`](agent) | API loopback et CLI JSON pour les harness d’agents ; [`run-windows.ps1`](agent/run-windows.ps1) lance le service Windows sans secret en ligne de commande. |
| [`windows/`](windows) | Codec Python v1 strict, hôte de compatibilité TCP pour données synthétiques, scripts d’installation Windows. |
| [`cloud/runpod/`](cloud/runpod) | Bootstrap supervisé et benchmark synthétique des services voix/nettoyage/LLM dans un Pod privé. |
| [`tests/`](tests) | Tests du serveur, du runtime RunPod et de régression du Core Swift. |
| [`scripts/`](scripts) | Builds iOS et macOS reproductibles. |
| [`docs/`](docs) | Protocole, sécurité, déploiement, revues, journal de décisions. |
| [`website/`](website) | Site vitrine. |

Les artefacts (DMG, `.ipa`, archives source, fichiers d’empreintes) ne sont pas versionnés.

## Lancer la démonstration

Données synthétiques uniquement : aucune voix, aucun nom, aucune note de patient.

**App macOS.** Voir [`mac/LISEZ-MOI-OUVRIR-DANS-XCODE.md`](mac/LISEZ-MOI-OUVRIR-DANS-XCODE.md) et [`docs/mac-build.md`](docs/mac-build.md).

```bash
git submodule update --init
cd mac/VoxLocal
./build-runtimes.sh
./setup.sh
./run.sh
```

**Hôte Python** (mock local en TCP brut, réservé au test synthétique) :

```bash
export VOXLOCAL_PAIRING_CODE='test-only-123456'
python3 server/voxlocal_server.py --mock --insecure-test-only --host 127.0.0.1
```

**API agent** (mock loopback, token fourni par l’environnement, jamais en argument) :

```bash
export VOXLOCAL_AGENT_TOKEN='un-token-local-d-au-moins-16-caracteres'
python3 -m agent.voxlocal_agent_api serve --mock
```

**iPhone / iPad.** Ouvrir `ios/RemoteScribePortable.xcodeproj` dans Xcode, choisir la Personal Team dans **Signing & Capabilities**, sélectionner l’appareil et cliquer **Run**. Détails dans [`docs/install-and-test.md`](docs/install-and-test.md) et [`docs/demo-runbook.md`](docs/demo-runbook.md).

## Vérifications locales

```bash
python3 -m unittest discover -s windows -p 'test_*.py' -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m unittest discover -s agent -p 'test_*.py' -v
python3 -m py_compile server/voxlocal_server.py windows/*.py agent/*.py cloud/runpod/*.py
(cd RemoteScribe && swift test)
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

## Position sécurité

Le mode mock non chiffré est réservé aux données synthétiques et exige `--mock --insecure-test-only`. Un endpoint GPU réel exige HTTPS serveur, secret d’appairage robuste et token GPU ; le mTLS, le pinning iOS, l’enrôlement/révocation, le DPA ZDR et la validation DPO restent à fermer avant toute donnée patient. Le serveur ne fait aucune persistance applicative par défaut. Le DMG macOS est signé ad hoc pour les essais locaux ; la notarisation, l’installateur Windows et la signature iOS de distribution restent des étapes de mise sur le marché.

## Documentation

- [`docs/release-readiness.md`](docs/release-readiness.md) : matrice de sortie, preuves actuelles et portes restantes avant pilote clinique.
- [`docs/protocol-reconstruction.md`](docs/protocol-reconstruction.md) : contrat wire Remote Scribe v1.
- [`docs/agent-api.md`](docs/agent-api.md) : API HTTP loopback et CLI machine-readable.
- [`docs/windows-deployment.md`](docs/windows-deployment.md) : installation, tâches et pare-feu Windows.
- [`docs/runpod-runtime.md`](docs/runpod-runtime.md) : runtime GPU privé dans RunPod.
- [`docs/architecture.md`](docs/architecture.md), [`docs/windows-security-plan.md`](docs/windows-security-plan.md), [`docs/decision-log.md`](docs/decision-log.md).
