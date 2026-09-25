# VoxLocal / Remote Scribe — prototype hospitalier

Ce dépôt contient le client iOS/iPadOS Remote Scribe et un hôte Windows de référence pour une architecture d’inférence sans persistance applicative locale.

## Arborescence

- [`source/PortableClient`](source/PortableClient) : projet Xcode canonique, UI SwiftUI, capture micro et historique Keychain.
- [`source/Core/Sources`](source/Core/Sources) : protocole `RemoteScribeCore` reconstruit depuis le binaire fourni.
- [`server/voxlocal_server.py`](server/voxlocal_server.py) : hôte de référence multi-plateforme, TLS 1.3, quotas, mode mock explicite et GPU OpenAI-compatible HTTPS.
- [`agent/voxlocal_agent_api.py`](agent/voxlocal_agent_api.py) : API loopback et CLI JSON pour les harness d'agents ; [`agent/run-windows.ps1`](agent/run-windows.ps1) lance le service Windows sans secret en ligne de commande.
- [`windows/remotescribe_protocol.py`](windows/remotescribe_protocol.py) : codec Python v1 strict ; [`windows/remotescribe_host.py`](windows/remotescribe_host.py) est un hôte de compatibilité TCP pour données synthétiques.
- [`docs/decision-log.md`](docs/decision-log.md) et [`docs/process-log.md`](docs/process-log.md) : décisions, preuves, délégation Astra/Luna et vérifications.
- [`docs/protocol-reconstruction.md`](docs/protocol-reconstruction.md) : contrat wire extrait du binaire macOS.
- [`docs/attached-core-audit.md`](docs/attached-core-audit.md) : comparaison des fichiers Core joints après la reconstruction initiale.
- [`docs/windows-security-plan.md`](docs/windows-security-plan.md) : menaces, ZDR, pare-feu, TLS/mTLS et critères pilote.
- [`docs/install-and-test.md`](docs/install-and-test.md) : où trouver le DMG, signer l’app iOS et brancher le GPU privé.
- [`VoxLocal-Agent-2026-09-24.dmg`](VoxLocal-Agent-2026-09-24.dmg) : build macOS reconstruit avec le runtime agent durci et sans secret embarqué.
- [`docs/agent-api.md`](docs/agent-api.md) : API HTTP loopback et CLI machine-readable pour les harness locaux.
- [`docs/agent-runtime-plan.md`](docs/agent-runtime-plan.md) : séparation voix/nettoyage/LLM et préparation RunPod.
- [`docs/ios-liquid-glass.md`](docs/ios-liquid-glass.md) : règles d’usage Liquid Glass, compatibilité iOS 16 et validation Xcode.
- [`docs/runpod-guide-audit.md`](docs/runpod-guide-audit.md) : audit du guide officiel et état de la connexion RunPod.
- [`docs/runpod-runtime.md`](docs/runpod-runtime.md) : bootstrap supervisé des services voix/nettoyage/LLM dans le Pod, sans secret ni endpoint inventé.
- [`cloud/runpod/benchmark.py`](cloud/runpod/benchmark.py) : benchmark synthétique des trois capacités, sans audio clinique ni appel au control plane.
- [`docs/mac-runtime-quality.md`](docs/mac-runtime-quality.md) : durcissements du runtime macOS, du trousseau et des moteurs natifs.
- [`docs/release-readiness.md`](docs/release-readiness.md) : matrice de sortie, preuves actuelles et portes restantes avant pilote clinique.
- [`docs/adversarial-product-review-2026-09-25.md`](docs/adversarial-product-review-2026-09-25.md) : revue ciblée des dérives de transport, mock, RunPod et iOS.
- [`docs/demo-runbook.md`](docs/demo-runbook.md) : démonstration YC reproductible avec données synthétiques.
- [`docs/windows-deployment.md`](docs/windows-deployment.md) : installation, tâches et pare-feu Windows.
- [`VoxLocal-Product-Source-2026-09-25.zip`](VoxLocal-Product-Source-2026-09-25.zip) : export source complet sans caches ni secrets ; SHA-256 `9b70a4a162dccd19bbac23b053a86ed8005be7e1a3b610e7add8b48f8c3c15af`.
- [`VoxLocal-Windows-Runtime-2026-09-25.zip`](VoxLocal-Windows-Runtime-2026-09-25.zip) : paquet Windows installable localement ; SHA-256 `22792f90624e04d0eca5b7ff38adbe236c167c19d4157a69016a455093dbb123`.
- [`RELEASE-CHECKSUMS-2026-09-25.txt`](RELEASE-CHECKSUMS-2026-09-25.txt) : empreintes SHA-256 des artefacts livrés.
- [`VoxLocal-Agent-Runtime.zip`](VoxLocal-Agent-Runtime.zip) : ancien paquet de compatibilité conservé pour reproduire les essais du 24 septembre ; utiliser le paquet Windows daté ou l’export source pour toute nouvelle installation.
- [`scripts/build-ios.sh`](scripts/build-ios.sh) : build iOS reproductible avec destination et cache configurables.

Le dossier `RemoteScribePortable/` est le miroir de l’archive d’origine pour les outils qui attendent son chemin historique. La source à ouvrir en priorité est [`source/PortableClient/RemoteScribePortable.xcodeproj`](source/PortableClient/RemoteScribePortable.xcodeproj), qui contient le Core reconstruit au même niveau.

## Vérifications locales

```bash
python3 -m unittest discover -s windows -p 'test_*.py' -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m unittest discover -s agent -p 'test_*.py' -v
python3 -m py_compile server/voxlocal_server.py windows/*.py
python3 -m py_compile agent/*.py cloud/runpod/*.py
swiftc -parse source/Core/Sources/*.swift source/PortableClient/RemoteScribePortable/*.swift
swiftc -typecheck source/Core/Sources/*.swift source/PortableClient/RemoteScribePortable/SecurePairingStore.swift
```

Des tests de régression compilent aussi le Core Swift avec `swiftc` et un pair réseau local. Le build Xcode sans signature passe avec le SDK iOS installé ; la signature sur appareil reste gérée par la Team personnelle dans Xcode.

## Position sécurité

Le mode mock non chiffré est réservé aux données synthétiques et exige `--mock --insecure-test-only`. Un endpoint GPU réel exige HTTPS serveur, secret d’appairage robuste et token GPU ; le mTLS, le pinning iOS, l’enrôlement/révocation, le DPA ZDR et la validation DPO restent à fermer avant toute donnée patient. Le serveur ne fait aucune persistance applicative par défaut. Le DMG macOS est signé ad hoc pour les essais locaux ; la notarisation, l’installateur Windows et la signature iOS de distribution restent des étapes de mise sur le marché.
