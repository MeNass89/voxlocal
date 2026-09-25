# Feuille de route

Mise à jour du 25 septembre 2026. Chaque ligne renvoie à la porte qu’elle ferme
ou au travail qui la porte. Les portes sont détaillées dans
[`release-readiness.md`](release-readiness.md).

## Maintenant — démontrable avec des données synthétiques

| Élément | État | Preuve |
|---|---|---|
| Dictée iPhone → Mac en TLS 1.3, code d’appairage, épinglage du certificat | livré | [`security-whitepaper.md`](security-whitepaper.md#transport), interop testée contre `RemoteScribeHost` |
| Appairage par QR code, onboarding iPhone, iPad en deux colonnes | livré (iOS 1.3) | [`ios-stability.md`](ios-stability.md) |
| Inférence locale sur Mac, serveur LLM gardé chaud, runtimes arm64 natifs | livré (VoxLocal 2.3.0) | [`mac-performance.md`](mac-performance.md) |
| Hôte Python et installateur Windows | exécutés en CI sur `windows-latest` | [`windows-deployment.md`](windows-deployment.md) |
| Image GPU privé RunPod, porte HTTPS, banc de mesure | conçus et exercés localement | [`docs/cloud-deployment.md`](cloud-deployment.md), [`runpod-runtime.md`](runpod-runtime.md) |
| API agent loopback | livrée | [`agent-api.md`](agent-api.md) |
| Harness clinique : dictée → brouillon → feu vert → écriture, sur portail mock | livré (vague 3) | [`harness/README.md`](../harness/README.md), [Agent et portail](security-whitepaper.md#agent-et-portail) |

## Ensuite — pour un pilote hospitalier

| Élément | Porte | Qui |
|---|---|---|
| Installer l’app sur un iPhone réel avec la Personal Team et faire une dictée réelle contre VoxLocal.app 2.3.0 | Apple, test physique | Nassim (Xcode, 5 minutes) |
| Mesurer les modèles recommandés (Whisper large-v3 turbo, Qwen2.5-3B) avec `scripts/bench-mac-inference.sh` | Modèles | dépôt, sur un Mac cible |
| Créer le compte RunPod, déployer, mesurer p50/p95 sur un vrai GPU | Fournisseur GPU | Nassim puis dépôt |
| Durée de rétention et suppression de l’historique dans VoxLocal | Données au repos | dépôt |
| Signature Developer ID et notarisation du DMG ; signature de distribution iOS | Distribution | compte Apple Developer |
| Essai de l’installateur sur un poste Windows du parc ; service Windows signé avec coffre de secrets | Déploiement poste | IT de l’hôpital + dépôt |
| DPA, zéro rétention et région du fournisseur GPU, si l’option est retenue | Fournisseur GPU | hôpital, fournisseur |
| Revue DPO/RSSI, AIPD | Conformité | hôpital |
| Accès au portail patient, puis client réel derrière le pont | Portail | hôpital, puis dépôt |
| Mesurer Qwen3.8-27B sur le Pod avec `harness/bench/` | Modèle de l’agent | dépôt, après le compte RunPod |
| Exécuter le harness (`run-web.ps1`, `run-feeder.ps1`, pont) sur un poste Windows | Déploiement poste | dépôt + IT de l’hôpital |

## Plus tard — pour un déploiement élargi

| Élément | Porte |
|---|---|
| Identité par appareil : certificat client mTLS émis par la CA de l’hôpital, enrôlement et révocation par MDM | Identité réseau |
| Journal d’audit défini avec le DPO | Journalisation |
| Validation clinique des textes réécrits, procédure d’incident | Validation clinique |
| Un seul paquet Swift pour le client iOS et le Core (aujourd’hui `ios/Core` et `RemoteScribe/Core`) | Maintenance |
| Transcription locale dans l’hôte Windows, sans endpoint GPU | Déploiement poste |
| Vague 4, boîte à outils médicale : protocoles de soins (entorse, etc.), facturation INAMI, prescriptions via xCare, montés comme plugins du harness | Validation clinique |
| Approbateur hors du processus `dsh` (aujourd’hui les deux jetons du pont vivent dans le même processus) | Harness clinique |
