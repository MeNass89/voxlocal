# Release readiness — VoxLocal

Date : 25 septembre 2026. Ce document sépare ce que le dépôt prouve de ce qui
nécessite un compte, un appareil, un fournisseur ou une validation hospitalière.
« Prêt à montrer » signifie démontrable avec des données synthétiques. « Prêt
clinique » exige les portes de sécurité et de conformité indiquées ci-dessous.

## État vérifié

| Surface | Preuve actuelle | État |
| --- | --- | --- |
| API/CLI agent | `agent/test_agent_api.py` : 8 tests ciblés ; Bearer loopback, contrats JSON, limites, erreurs amont et timeouts | Prêt pour harness synthétique |
| Hôte serveur | `tests/` : 12 tests ; framing, TLS/mock, quotas, backend GPU et RunPod readiness | Prêt pour intégration contrôlée |
| Compatibilité Windows | `windows/` : 5 tests ; fragmentation, séquences, STOP et limites audio ; installateur local dans `windows/install-runtime.ps1` | Prêt pour harnais et pilote synthétique |
| Runtime RunPod | `cloud/runpod/start-all.sh`, `check-services.py`, `benchmark.py`, configuration placeholder et runbook | Prêt à copier dans un Pod ; benchmark synthétique disponible ; pas de Pod provisionné |
| Mac | `swift build` passe ; token cloud dans Keychain, aucun faux succès Whisper, subprocess sans deadlock, HTTP distant refusé ; version 2.1.0 (build 3) | DMG arm64 ad hoc reconstruit et smoke-testé |
| iPhone/iPad | build Xcode unsigned passé ; Liquid Glass natif avec fallback iOS 16 ; runtime iOS 27 installé ; version 1.1 (build 2) | Signature Personal Team et test physique encore locaux ; le premier service CoreSimulator d’installation tierce est resté bloqué |
| Documentation | architecture, API, RunPod, sécurité, décisions, déploiement Windows et journal de processus présents | Traçable |

Le DMG actuellement livré est `VoxLocal-Agent-2026-09-24.dmg`, SHA-256
`d9400e33b7fc6acccfced009f898f2b4e79700da2e15259d1c3ef90dedfcf2c4`. Le bundle
est arm64, signé ad hoc, et son launcher agent a passé un smoke test `serve
--mock` puis `clean --stdin` avec Python 3.14.

## Portes avant pilote clinique

1. **Identité réseau** : fournir certificats gérés, pinning ou mTLS, enrôlement,
   rotation et révocation d’appareil. Le code d’appairage seul ne suffit pas.
2. **Fournisseur GPU** : enregistrer région, image et digest, versions CUDA et
   modèles, logs, snapshots, rétention, suppression et DPA/ZDR. Un header
   `X-Remote-Scribe-ZDR` ne constitue pas une preuve contractuelle.
3. **Modèles** : benchmark synthétique séparé voix, nettoyage et LLM ; mesurer
   latence, VRAM, coût, saturation, erreurs et stabilité avant de choisir une
   taille Qwen ou un modèle Whisper.
4. **Déploiement poste** : valider le paquet Windows sur un poste réel, puis
   remplacer la tâche planifiée de démonstration par un service signé avec coffre
   Credential Manager ou DPAPI ; signer et notariser le DMG macOS, puis signer
   l’app iOS avec le profil de distribution approprié.
5. **Validation clinique** : revue DPO/sécurité, politique de rétention,
   procédure d’incident, test de suppression, journalisation sans PHI et
   validation humaine des sorties de nettoyage avant usage réel.

## Démo reproductible

Le parcours YC peut être montré sans données patient : démarrer l’API agent en
`--mock`, envoyer un WAV synthétique avec le CLI, démarrer le serveur mock
explicitement marqué, puis montrer l’iPhone comme microphone et le Mac comme
hôte. Pour RunPod, copier le bootstrap et utiliser uniquement les contrôles
`/v1/models` avec un token Pod-local ; aucun endpoint ou modèle n’est inventé
dans le dépôt.

Le DMG de démonstration doit être régénéré après toute modification de la source
Mac :

```bash
./scripts/build-macos.sh
codesign --verify --deep --strict /tmp/voxlocal-desktop-app/VoxLocal.app
shasum -a 256 VoxLocal-Agent-2026-09-24.dmg
```

La signature actuelle est ad hoc pour essais locaux. Elle ne vaut ni
notarisation ni distribution clinique.

L’export source complet est `VoxLocal-Product-Source-2026-09-25.zip`, vérifié
avec `unzip -t` ; SHA-256 :
`9b70a4a162dccd19bbac23b053a86ed8005be7e1a3b610e7add8b48f8c3c15af`. Il exclut
les caches Xcode/SwiftPM, les `dist` générés, les images DMG, les anciens ZIP et
les `__pycache__`.

Le paquet Windows séparé est `VoxLocal-Windows-Runtime-2026-09-25.zip`, vérifié
avec `unzip -t` ; SHA-256 :
`22792f90624e04d0eca5b7ff38adbe236c167c19d4157a69016a455093dbb123`. Aucun
PowerShell n’est installé sur le Mac de build : l’analyse de syntaxe Windows est
statique et l’exécution doit être faite sur un poste Windows de validation.
