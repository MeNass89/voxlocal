# Release readiness — VoxLocal

Date : 25 septembre 2026. Ce document sépare ce que le dépôt prouve de ce qui
nécessite un compte, un appareil, un fournisseur ou une validation hospitalière.
« Prêt à montrer » signifie démontrable avec des données synthétiques. « Prêt
clinique » exige les portes de sécurité et de conformité indiquées ci-dessous.

Versions : VoxLocal.app 2.3.0 (build 5), Remote Scribe iOS 1.3 (build 4).

## État vérifié

| Surface | Preuve actuelle | État |
| --- | --- | --- |
| iPhone → Mac | TLS 1.3 + pinning TOFU, code d’appairage obligatoire, verrou 5 échecs / 60 s par adresse, interop prouvée contre `RemoteScribeHost` (`tests/test_real_host_interop.py`) ; un QR code ne remplace jamais une empreinte déjà épinglée | Prêt à montrer ; dictée sur iPhone physique encore à faire |
| Mac | VoxLocal 2.3.0 : `swift build` passe ; `llama-server` gardé chaud, vérifié par `lsof` avant de recevoir sa clé, repli `llama-cli` ; runtimes arm64 natifs ; téléchargement des modèles vérifié par SHA-256 ; macOS 15 ou plus récent (`LSMinimumSystemVersion` 15.0) | Prêt à montrer ; DMG signé ad hoc |
| iPhone/iPad | iOS 1.3 : onboarding, appairage QR, retour de résultat, iPad en deux colonnes ; 8 XCTest (`RemoteScribePortableTests`) verts sur simulateur ; build `iphoneos` non signé en CI | Signature Personal Team et test physique encore locaux |
| Core Swift | `RemoteScribe` : `swift test`, 8 cas (contrat de séquence, `framesSent`, identité TLS, verrou d’appairage) | Prêt |
| Hôte serveur Python | `tests/` : 55 tests sur macOS (les tests Swift, bash et POSIX se sautent ailleurs) ; framing, TLS/mock, épinglage, quotas, backend GPU, runtime RunPod, régression du Core Swift | Prêt pour intégration contrôlée |
| Windows | `windows/` : 5 tests ; installateur exécuté en CI sur `windows-latest` (installation, import de l’agent depuis la venv, désinstallation, identité TLS) | Prêt pour harnais et pilote synthétique ; pas encore sur un poste du parc |
| API/CLI agent | `agent/` : 15 tests ; Bearer loopback, contrats JSON, limites, erreurs amont, timeouts | Prêt pour harness synthétique |
| Harness clinique : pont portail, feeder, boucle | `harness/tests/` : 58 tests (pont et mock : approbation 403/409, rejeu idempotent après redémarrage, citations, liaison patient ; feeder : reprise sans rejeu ni trou ; boucle : vrai `dsh` 0.1.7-rc.2 + vrai pont + quatre plugins, modèle scripté, politique `never` et absence de répondeur ⇒ aucune écriture, feu vert ⇒ une écriture par brouillon) | Prêt à montrer sur mock ; portail réel fermé |
| Harness clinique : plugins `dsh` | vitest : 41 tests (`portail-tools` 13, `scribe-approval` 12, `scribe-persona` 7, `voxlocal-tools` 9) | Prêt à montrer |
| Harness clinique : lanceurs | [`harness/run-web.sh`](../harness/run-web.sh), [`run-web.ps1`](../harness/run-web.ps1), [`run-feeder.ps1`](../harness/ingest/run-feeder.ps1) : boucle locale seulement, secrets par l’environnement ; les `.ps1` exécutés sous `pwsh` 7.6 sur macOS ; l’étape « Parse every PowerShell script » du job Windows les couvre (`**/*.ps1`), pas encore exécutée sur ces fichiers | Pas encore exécutés sous Windows |
| Modèle de l’agent | banc d’appel d’outils ([`harness/bench/`](../harness/bench/README.md)) exercé contre Qwen2.5-0.5B local seulement | Qwen3.8-27B jamais mesuré |
| GPU privé | image RunPod, déploiement, porte HTTPS et banc de mesure décrits dans [`docs/cloud-deployment.md`](cloud-deployment.md) ; exercés localement | Aucun Pod provisionné, aucune mesure GPU |
| Documentation | [livre blanc sécurité](security-whitepaper.md), [FAQ IT](faq-hospital-it.md), [feuille de route](roadmap.md), [démo](demo-runbook.md) | Traçable |

CI GitHub Actions : run 36130936691 sur le commit `766015b`, quatre jobs verts
(ubuntu Python 3.11 et 3.12 ; Windows : suites, installateur, désinstallation,
identité TLS ; macOS : `swift test`, build VoxLocal, suites Python dont l’interop
réelle, build iOS non signé). Les XCTest iOS tournent en local sur simulateur,
pas encore en CI.
Le job `harness` (ubuntu et macOS : installation verrouillée de `dsh` et des
plugins, vitest, `harness/tests/`, lanceurs PowerShell sous `pwsh`) est ajouté le
25 septembre ; il n’a pas encore tourné sur GitHub, ses commandes passent en
local (macOS, Node 24, Python 3.12).

Performances Mac mesurées le 25 septembre 2026 sur un M2 16 Go avec les plus
petits modèles (`ggml-tiny.bin`, Qwen2.5-0.5B) : transcription de 19,8 s d’audio
en 0,657 s, réécriture Medical en 1,203 s avec le serveur chaud contre 2,048 s à
froid ([`mac-performance.md`](mac-performance.md)). Les modèles recommandés
restent à mesurer.

## Portes avant pilote clinique

1. **Installation physique** : signer l’app sur un iPhone avec la Personal Team
   (action locale dans Xcode, 5 minutes) et faire une dictée réelle contre
   VoxLocal.app 2.3.0.
2. **Identité des appareils** : certificat client mTLS émis par la CA de
   l’hôpital, enrôlement et révocation par MDM. Le code d’appairage et
   l’épinglage du certificat serveur ne suffisent pas pour un pilote élargi.
3. **Fournisseur GPU** (si l’option est retenue) : compte RunPod, benchmark GPU
   réel, puis région, image et digest, versions CUDA et modèles, journaux,
   instantanés, rétention, suppression et DPA/ZDR. Un en-tête
   `X-Remote-Scribe-ZDR` ne constitue pas une preuve contractuelle.
4. **Modèles** : mesurer latence, mémoire et stabilité des modèles recommandés
   avant de fixer une taille de Whisper ou de Qwen.
5. **Déploiement poste** : valider le paquet Windows sur un poste réel, puis
   remplacer la tâche planifiée de démonstration par un service signé avec coffre
   Credential Manager ou DPAPI ; signer (Developer ID) et notariser le DMG macOS ;
   signer l’app iOS avec le profil de distribution approprié.
6. **Validation clinique et conformité** : revue DPO/sécurité, AIPD, politique
   de rétention de l’historique Mac, procédure d’incident, test de suppression,
   journalisation sans PHI et validation humaine des textes réécrits avant usage
   réel.

### Portes du harness clinique

7. **Accès au portail** : le portail de l’hôpital est fermé ; tout tourne sur le
   mock enregistré. Il faut l’accès, puis exécuter le client réel derrière le
   pont (jamais exécuté à ce jour), avec les identifiants lus par le pont seul.
8. **Modèle réel** : mesurer Qwen3.8-27B sur le Pod avec
   [`harness/bench/`](../harness/bench/README.md) (appels d’outils valides,
   brouillons SOAP complets, latence) ; aujourd’hui seul Qwen2.5-0.5B local a été
   mesuré, et la boucle est testée avec un modèle scripté.
9. **Windows** : exécuter `run-web.ps1`, `run-feeder.ps1` et le pont sur un poste
   Windows ; aujourd’hui ils sont exécutés sous `pwsh` sur macOS seulement.
10. **Séparation des jetons** : sortir l’approbateur du processus `dsh` avant
    d’ajouter au preset tout outil générique (terminal, fichiers) ; voir
    [Agent et portail](security-whitepaper.md#agent-et-portail).

## Démo reproductible

Le parcours de 90 secondes, ses fallbacks et la remise à zéro sont dans
[`demo-runbook.md`](demo-runbook.md). L’API agent se montre en `--mock`, sans
réseau. Pour RunPod, aucun endpoint ou modèle n’est inventé dans le dépôt.

L’app Mac exige macOS 15 ou plus récent (`LSMinimumSystemVersion` 15.0).

Le DMG de démonstration se régénère après toute modification de la source Mac.
Les artefacts ne sont pas versionnés : on les reconstruit depuis le dépôt et on
calcule leur empreinte au moment de les distribuer.

```bash
./scripts/build-macos.sh
codesign --verify --deep --strict /tmp/voxlocal-desktop-app/VoxLocal.app
```

La signature actuelle est ad hoc pour essais locaux. Elle ne vaut ni
notarisation ni distribution clinique.
