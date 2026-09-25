# VoxLocal / Remote Scribe

Dictée médicale qui reste à l’hôpital : l’iPhone sert de micro, le poste de l’hôpital (Mac ou Windows) transcrit et met en forme le texte, puis le colle dans le logiciel ouvert.

![VoxLocal sur Mac (écran iPhone : QR code d’appairage, code, empreinte TLS, appareils connectés) et Remote Scribe sur iPhone, connecté au poste](docs/screenshots/hero.png)

- **Local par défaut.** whisper.cpp et llama.cpp tournent sur le poste. Aucune API cloud n’est nécessaire pour dicter.
- **L’iPhone comme micro.** L’app Remote Scribe envoie l’audio au poste en TLS 1.3, après appairage par QR code et vérification de l’empreinte du certificat.
- **GPU privé en option.** Pour des modèles plus gros, un GPU dédié derrière une porte HTTPS authentifiée (RunPod), à valider contractuellement avant toute donnée patient.

Prototype publié pour relecture et audit de sécurité ([`LICENSE`](LICENSE), [`CONTRIBUTING.md`](CONTRIBUTING.md)). Versions actuelles : VoxLocal.app 2.3.0 (build 5), Remote Scribe iOS 1.3 (build 4).

## Essayer en 5 minutes

Données synthétiques uniquement : aucune voix, aucun nom, aucune note de patient.

**Sans rien compiler : l’hôte Python et l’API agent** (Python 3.11 ou plus récent, aucune dépendance tierce). L’hôte mock écoute en TCP brut sur `127.0.0.1` ; ce mode est réservé au test synthétique :

```bash
export VOXLOCAL_PAIRING_CODE='test-only-123456'
python3 server/voxlocal_server.py --mock --insecure-test-only --host 127.0.0.1
```

L’API agent en mock, dans un second terminal (token lu dans l’environnement, jamais en argument) :

```bash
export VOXLOCAL_AGENT_TOKEN='un-token-local-d-au-moins-16-caracteres'
python3 -m agent.voxlocal_agent_api serve --mock
```

**App Mac** (macOS 15 ou plus récent, Apple Silicon, CMake pour les runtimes ; la première compilation de whisper.cpp et llama.cpp prend une dizaine de minutes). Au premier lancement, l’écran Réglages › Intelligence artificielle propose de télécharger le modèle Whisper recommandé (574 MB). Détails : [`docs/mac-build.md`](docs/mac-build.md).

```bash
git submodule update --init
cd mac/VoxLocal
./build-runtimes.sh
./setup.sh
./run.sh
```

Pour un DMG signé ad hoc, depuis la racine : `./scripts/build-macos.sh`.

**iPhone / iPad.** Ouvrir `ios/RemoteScribePortable.xcodeproj` dans Xcode, choisir votre Personal Team dans **Signing & Capabilities**, sélectionner l’appareil, puis **Run**. Sur le Mac, ouvrir l’écran **iPhone** de VoxLocal et scanner le QR code avec l’app. Parcours complet : [`docs/demo-runbook.md`](docs/demo-runbook.md) et [`docs/install-and-test.md`](docs/install-and-test.md).

## Harness clinique

Une couche d’agent sur le poste du médecin, dans [`harness/`](harness/README.md). La dictée terminée et nettoyée arrive à un agent ([DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) `dsh` 0.1.7-rc.2, modèle Qwen3.8-27B servi par le GPU privé). L’agent lit le dossier, prépare un brouillon par section avec des citations exactes de la dictée, puis **attend un feu vert explicite** du médecin dans le chat web avant d’écrire dans le portail patient. Le pont portail, pas l’agent, décide : sans approbation humaine de ce brouillon précis, il refuse l’écriture.

Le portail réel est fermé pour l’instant : le pont tourne sur un **mock enregistré** (patients synthétiques) qui reproduit ses contraintes.

```bash
export VOXLOCAL_LLM_URL='https://<pod>:8443/llm/v1' VOXLOCAL_LLM_TOKEN='…'
export PORTAIL_BRIDGE_TOKEN="$(openssl rand -hex 24)" PORTAIL_BRIDGE_APPROVER_TOKEN="$(openssl rand -hex 24)"
python3 -m harness.bridge.portail_bridge --backend mock &   # pont portail sur 127.0.0.1:47368
harness/run-web.sh                                          # Windows : harness\run-web.ps1
```

Architecture, lancement, posture de sécurité et tests : [`harness/README.md`](harness/README.md). Détail sécurité : [Agent et portail](docs/security-whitepaper.md#agent-et-portail).

## Sécurité en une page

- Transport iPhone → poste en TLS 1.3. L’iPhone épingle le SHA-256 du certificat DER du poste (confirmation à la première connexion, ou empreinte lue dans le QR code). Une empreinte qui change est refusée avant tout envoi d’audio ; un QR code ne remplace jamais une empreinte déjà épinglée.
- Code d’appairage obligatoire ; 5 échecs depuis une même adresse bloquent cette adresse pendant 60 s.
- Hôtes Python sans persistance applicative. Sur Mac, l’historique des dictées (audio et texte) reste dans le dossier local de l’utilisateur.
- Secrets dans le Keychain (macOS, iOS) ou l’environnement du service (Windows), jamais en argument de processus ni dans les journaux. Les journaux ne contiennent ni texte dicté ni audio.
- Le mode non chiffré n’existe que pour le mock synthétique sur loopback (`--mock --insecure-test-only`).

Détails, fichier par fichier : [`docs/security-whitepaper.md`](docs/security-whitepaper.md). Questions des équipes IT : [`docs/faq-hospital-it.md`](docs/faq-hospital-it.md).

## Ce qui n’est pas encore fait

Ces portes dépendent d’un compte, d’un appareil, d’un fournisseur ou de l’hôpital ; le code ne peut pas les fermer seul.

- **Apple** : installation sur iPhone par la Personal Team (action locale dans Xcode), puis signature de distribution iOS, signature Developer ID et notarisation du DMG.
- **GPU privé** : aucun Pod RunPod n’a été provisionné ; le benchmark GPU réel attend un compte.
- **Identité des appareils** : certificats clients mTLS, enrôlement et révocation par MDM avec la CA de l’hôpital.
- **Conformité** : DPA et zéro rétention (ZDR) du fournisseur GPU, validation DPO, politique de rétention de l’historique Mac.
- **Validation clinique** du flux et des textes réécrits.
- **Windows** sur un vrai poste hospitalier : l’installateur est exécuté en CI, pas encore sur un poste du parc, et le service signé reste à faire.
- **Portail patient** : accès fermé ; le harness écrit dans un mock enregistré. Le modèle Qwen3.8-27B n’a pas encore été mesuré sur le Pod, et le harness n’a pas encore tourné sur un poste Windows.

Suivi détaillé : [`docs/release-readiness.md`](docs/release-readiness.md) et [`docs/roadmap.md`](docs/roadmap.md).

## Arborescence

| Dossier | Contenu |
|---|---|
| [`ios/`](ios) | App iPhone/iPad Remote Scribe : projet [`RemoteScribePortable.xcodeproj`](ios/RemoteScribePortable.xcodeproj), SwiftUI, capture micro, appairage QR, épinglage ; client Core durci dans [`ios/Core/Sources`](ios/Core/Sources). |
| [`RemoteScribe/`](RemoteScribe) | Paquet Swift `RemoteScribeCore` : protocole, serveur TLS, garde d’appairage, hôte CLI `RemoteScribeHost`. Source de vérité du contrat wire. |
| [`mac/VoxLocal/`](mac/VoxLocal) | App macOS VoxLocal : embarque le serveur `RemoteScribeCore`, whisper.cpp et llama.cpp (sous-modules dans `Vendor/src`). |
| [`server/`](server) | Hôte Python de référence [`voxlocal_server.py`](server/voxlocal_server.py) pour Windows et macOS : TLS 1.3, quotas, mock explicite, GPU OpenAI-compatible en HTTPS. |
| [`agent/`](agent) | API loopback et CLI JSON pour les harness d’agents ; [`run-windows.ps1`](agent/run-windows.ps1) lance le service Windows sans secret en ligne de commande. |
| [`windows/`](windows) | Installateur, désinstallateur, identité TLS et pare-feu Windows ; codec Python v1 et hôte de compatibilité pour tests synthétiques. |
| [`harness/`](harness) | Harness clinique : profil `dsh` « scribe », quatre plugins (dictées, outils portail, feu vert, persona), pont portail et mock enregistré, feeder de dictées, lanceurs macOS et Windows. |
| [`cloud/runpod/`](cloud/runpod) | Runtime GPU privé : supervision, porte HTTPS, banc de mesure synthétique. |
| [`tests/`](tests) | Tests du serveur, du runtime RunPod, de régression du Core Swift et d’interopérabilité contre le vrai `RemoteScribeHost`. |
| [`scripts/`](scripts) | Builds iOS et macOS, identité TLS macOS/Linux, banc de mesure Mac. |
| [`docs/`](docs) | Sécurité, protocole, déploiement, revues, journal de décisions. |
| [`website/`](website) | Site produit. |

Les artefacts (DMG, `.ipa`, archives) ne sont pas versionnés : ils se reconstruisent depuis le dépôt.

## Vérifications

Depuis la racine du dépôt :

```bash
python3 -m unittest discover -s windows -p 'test_*.py' -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m unittest discover -s agent -p 'test_*.py' -v
python3 -m py_compile server/voxlocal_server.py windows/*.py agent/*.py cloud/runpod/*.py
(cd RemoteScribe && swift test)
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
python3 -m unittest discover -s harness/tests -t . -v   # après (cd harness/profile && pnpm install --frozen-lockfile)
for d in harness/plugins/*/; do (cd "$d" && pnpm install --frozen-lockfile && pnpm test); done
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

| Suite | Tests au 25 septembre 2026 |
|---|---|
| `windows/` | 5 |
| `tests/` | 55 sur macOS, dont 1 sauté sans `caddy` (hors macOS, les tests Swift, bash et POSIX se sautent eux-mêmes) |
| `agent/` | 15 |
| `RemoteScribe` (`swift test`) | 8 |
| `harness/tests/` (pont, feeder, boucle `dsh`) | 58 |
| `harness/plugins/*` (vitest) | 41 (13 + 12 + 7 + 9) |
| iOS XCTest (`RemoteScribePortableTests`, simulateur) | 8 |

La CI GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) exécute ces suites sur ubuntu (Python 3.11 et 3.12), Windows (installateur réel, désinstallation, identité TLS) et macOS (Swift, build VoxLocal, suites Python dont l’interop contre `RemoteScribeHost`, build iOS non signé). Run 36130936691 sur le commit `766015b` : quatre jobs verts. Un cinquième job, `harness` (ubuntu et macOS : installation verrouillée de `dsh` et des plugins, vitest, tests Python du harness, lanceurs PowerShell sous `pwsh`), est ajouté le 25 septembre et n’a pas encore tourné sur GitHub ; ses commandes passent en local. Les XCTest iOS tournent en local sur simulateur.

## Documentation

- [`docs/security-whitepaper.md`](docs/security-whitepaper.md) : flux de données, transport, données au repos, secrets, journalisation, fournisseur GPU.
- [`docs/faq-hospital-it.md`](docs/faq-hospital-it.md) : réponses courtes pour les équipes informatiques.
- [`docs/release-readiness.md`](docs/release-readiness.md) : état vérifié et portes restantes avant pilote clinique.
- [`docs/roadmap.md`](docs/roadmap.md) : maintenant, ensuite, plus tard.
- [`docs/demo-runbook.md`](docs/demo-runbook.md) : démonstration de 90 secondes.
- [`docs/pitch.md`](docs/pitch.md) : one-pager (en anglais).
- [`docs/architecture.md`](docs/architecture.md), [`docs/protocol-reconstruction.md`](docs/protocol-reconstruction.md) : architecture et contrat wire Remote Scribe v1.
- [`docs/mac-build.md`](docs/mac-build.md), [`docs/mac-performance.md`](docs/mac-performance.md) : build et performances de l’app Mac.
- [`docs/windows-deployment.md`](docs/windows-deployment.md), [`docs/agent-api.md`](docs/agent-api.md), [`docs/runpod-runtime.md`](docs/runpod-runtime.md) : Windows, API agent, runtime GPU.
- [`docs/ios-stability.md`](docs/ios-stability.md), [`docs/decision-log.md`](docs/decision-log.md), [`docs/process-log.md`](docs/process-log.md) : app iOS, décisions, journal de travail.
