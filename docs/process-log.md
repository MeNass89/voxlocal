# Journal de processus

Ce fichier explique comment le chantier a été mené afin qu'un autre modèle puisse reprendre sans deviner les choix.

## 24 septembre 2026 — reconstruction

### 1. Inventaire

Le dossier initial ne contenait que `PortableClient.zip`, `VoxLocal.dmg` et deux captures. Le ZIP contenait le client iOS, le projet Xcode, un README et deux PDF parasites. Le `project.pbxproj` référençait `../Core/Sources/RemoteProtocol.swift`, `FrameCodec.swift` et `RemoteClient.swift`, absents de l'archive.

### 2. Preuves binaires

Le DMG a été monté en lecture seule. Le binaire `VoxLocal` a été inspecté avec `strings`, `nm`, `swift-demangle` et `otool`. Cette méthode a permis de confirmer le port 47365, la version 1, la trame big-endian, la taille maximale 1 MiB, les types de payload, les états, les raw values backend, le codec audio et les endpoints GPU OpenAI-compatible. Les détails exacts et les hypothèses sont dans [`protocol-reconstruction.md`](protocol-reconstruction.md).

### 3. Travail parallèle

- **Reconstruction protocole** : analyse des symboles, du framing et des structures Codable.
- **Windows + sécurité** : hôte asyncio, validation stricte, limites de session, ZDR mémoire, HTTPS GPU, pare-feu Private, plan TLS/mTLS et critères pilote.
- **UI** : passe SwiftUI orientée hôpital, Dynamic Type, VoiceOver, erreurs actionnables, historique confirmé et contexte produit/design.
- **Revue finale difficile** : un agent Astra est chargé de relire le résultat de manière adversariale.
- **Audit documentaire simple** : un agent Luna vérifie les commandes et liens sans consommer un raisonnement lourd.

Les deux dernières tâches sont explicitement séparées selon le coût cognitif demandé : Astra pour la revue intellectuelle et Luna pour le contrôle mécanique/documentaire.

### 4. Choix d'implémentation

Le dossier [`ios`](../ios) (alors `source/`) est la base Xcode canonique ; le miroir `RemoteScribePortable/` de l’archive n’est plus versionné. Les trois fichiers Core manquants y ont été recréés avec les API appelées par le client. `server/voxlocal_server.py` est l’hôte de référence Windows/macOS : TLS obligatoire avec un GPU, mode mock local explicitement marqué, annonce DNS-SD facultative et quotas. `windows/` garde le codec et un hôte legacy pour tests synthétiques.

La persistance applicative serveur est absente par défaut : buffer audio en mémoire, suppression à la fin, aucun texte dans les logs. Le GPU reste soumis à un DPA/ZDR vérifié séparément. L'historique iOS est mémoire seule par défaut ; sa conservation est opt-in dans le Keychain `ThisDeviceOnly`, avec suppression confirmée ou tombstone.

Le protocole v1 historique reste supporté pour compatibilité, mais le client active TLS pour les nouvelles installations. Le serveur réel écoute en TLS 1.3 ; trust store géré, pinning/mTLS et provisioning sont des critères de pilote avant données patient.

### 5. Vérification

Les changements sont acceptés uniquement après une vérification reproductible :

```bash
python3 -m unittest discover -s windows -p 'test_*.py' -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m py_compile server/voxlocal_server.py windows/*.py
swiftc -parse ios/Core/Sources/*.swift ios/RemoteScribePortable/*.swift
swiftc -typecheck ios/Core/Sources/*.swift ios/RemoteScribePortable/SecurePairingStore.swift
```

Le build Xcode final doit encore être exécuté sur une machine équipée du SDK iOS et d'une Team Apple ; l'environnement de travail ne fournit que les Command Line Tools.

### 5. Boucle de revue et durcissement

La revue Astra a rendu la batterie de tests plus exigeante : elle compile le
Core Swift réel sur macOS et le confronte à un pair socket indépendant, avec
fragmentation, deux sessions, 20 producteurs audio concurrents, barrière STOP,
EOF puis reconnexion. Elle a aussi signalé les divergences entre les deux hôtes
Python. Le serveur `server/voxlocal_server.py` est désormais la référence ; le
fichier sous `windows/` reste un harnais de compatibilité explicitement non
clinique.

Les garde-fous ajoutés après cette revue sont : TLS obligatoire pour un backend
GPU, mode TCP non chiffré uniquement avec `--mock --insecure-test-only`, code
d’appairage robuste, limites de connexions/par IP/inférence, backoff des échecs,
validation JSON stricte (doublons et constantes non finies refusés), timeouts,
refus des redirections et proxies ambiants GPU, réponse bornée, en-tête ZDR, suppression des copies
PCM après inférence et refus des sessions vides ou des STOP incohérents.

La passe iOS a ensuite traité le cycle audio : admission fermée avant STOP,
drain du convertisseur, interruptions et pertes de route visibles, callbacks
obsolètes ignorés, délais bornés et reconnexion explicite. L’historique devient
mémoire seule par défaut ; sa persistance est opt-in dans le Keychain appareil
uniquement, avec tombstone si l’effacement n’est pas confirmé. Bonjour affiche
des candidats mais ne déclenche plus de connexion automatique.

À ce stade historique, les limites restantes étaient séparées du code : le build iOS/Xcode, un vrai test
TLS avec certificats gérés, le réseau Windows, le fournisseur GPU et les preuves
contractuelles ZDR/DPA nécessitent leurs environnements respectifs. Voir
[`final-hard-review.md`](final-hard-review.md) et [`ios-stability.md`](ios-stability.md).

### 24 septembre 2026 — API locale et runtime d'agents

La priorité a ensuite été déplacée vers l'interface d'intégration des agents,
avant de prétendre livrer un nouveau DMG. Un agent Astra a conçu et implémenté
`agent/voxlocal_agent_api.py` : service loopback sur `127.0.0.1:47366`, CLI
`voxlocal-agent`, contrat JSON versionné, Bearer local obligatoire, limites de
taille, JSON strict, absence de persistance et chat désactivé par défaut. Le
service expose des capacités distinctes pour transcription, nettoyage et LLM ;
le nettoyage peut viser un petit modèle dédié, tandis que le chat peut viser le
grand modèle configuré.

La revue a ajouté une capacité concurrente bornée et un refus explicite
`server_busy` au lieu d'une file implicite. Elle a aussi vérifié que le CLI
refuse les redirections et les proxies ambiants, borne les réponses et ne
reproduit pas de secrets dans les erreurs. Les tests API sont passés de 4 à 5
cas, avec rejet des clés JSON dupliquées, des valeurs non finies et des query
strings d'endpoint.

Le Pod RunPod réel a été documenté sans exécuter de commande distante : son
bootstrap de test est `bash /workspace/voxlocal/start-all.sh`, et son token est
lu localement au Pod avec `cat /workspace/voxlocal/api-token`. Le contenu du
token ne doit pas quitter le Pod. L'installation du plugin/MCP RunPod n'a pas
abouti dans cette session car le client Codex local échoue avant écriture avec
`Model provider local_codex_proxy not found`; aucun secret ni changement RunPod
n'a donc été enregistré. Voir [`runpod-guide-audit.md`](runpod-guide-audit.md).

Le runtime a ensuite été exporté dans `VoxLocal-Agent-Runtime.zip` avec son
shim d'installation `setup.py`, le `pyproject.toml`, le launcher PowerShell et
les tests/documents associés. L'archive ne contient aucun token, endpoint ou
modèle propriétaire.

Après confirmation que le test se fera avec un compte Apple gratuit, la Team
prototype codée en dur (`37KRYA2Z5Q`) a été retirée des deux copies du projet
Xcode. Xcode pourra ainsi choisir la Team personnelle de l'utilisateur et
générer le provisioning hebdomadaire sans exposer de certificat dans le dépôt.

### 24 septembre 2026 — Liquid Glass et build Xcode réel

Le SDK iOS 27 de Xcode 27.0 est maintenant installé et son premier lancement a
été terminé dans l’interface Xcode. La compilation unsigned des deux projets
iOS passe avec `CODE_SIGNING_ALLOWED=NO`, ce qui valide les imports SwiftUI,
Network, AVFoundation et Security dans le SDK réel. Les destinations physiques
appariées sont visibles, dont l’iPhone apparié ; le runtime iOS 27 du
simulateur a ensuite été installé et son premier appareil a démarré. La
signature reste volontairement dans Xcode avec la Personal
Team du compte gratuit.

Une passe UI a appliqué les API Liquid Glass natives avec un garde
`if #available(iOS 26.0, *)`. Le bouton de dictée utilise
`GlassProminentButtonStyle`, le bouton de connexion et les actions compactes
utilisent `GlassButtonStyle`, et le groupe d’actions proches passe par
`GlassEffectContainer`. Le Picker segmenté, le Form, le Toggle et la barre de
navigation restent des contrôles SwiftUI natifs ; ils adaptent eux-mêmes leurs
matériaux aux réglages d’accessibilité. Les surfaces de transcription gardent
un matériau contrasté plutôt qu’un effet de verre décoratif, afin de ne pas
affaiblir la lecture du texte médical. Reduce Motion coupe les animations du
niveau audio. Les choix détaillés et les commandes de vérification sont dans
[`ios-liquid-glass.md`](ios-liquid-glass.md).

Le build macOS a ensuite été exécuté depuis la source exportée. Swift Package
Manager a produit le binaire arm64 ; les runtimes Whisper et Llama existants
restent x86_64 et nécessitent Rosetta sur Apple Silicon. La première signature
depuis iCloud Drive a été refusée parce que Finder réinjectait des attributs
`com.apple.FinderInfo`/`com.apple.provenance` pendant la copie. Le correctif est
de construire le bundle de travail dans `/tmp` avant signature, puis de créer
l’image depuis un staging local. Un DMG de démonstration a été produit (les
artefacts ne sont pas versionnés et leurs empreintes ne sont pas reprises ici).
`codesign --verify --deep --strict` passe sur le bundle ; le lanceur agent a
été exécuté avec Python 3.14 et l’image montée en lecture seule confirme la
présence des sources, docs et shim sans token.

### 25 septembre 2026 — durcissement Mac, RunPod et release gate

L’audit de la source Mac a supprimé trois comportements qui pouvaient tromper
un opérateur : les tokens cloud sont migrés vers le Keychain et ne sont plus
écrits dans `settings.json`, les sorties Whisper/llama passent par des fichiers
temporaires afin d’éviter un deadlock de pipes, et l’absence d’un modèle
Whisper renvoie désormais une erreur explicite au lieu d’un texte de mock. Le
Remote Scribe respecte aussi les préférences auto-collage/presse-papier. Les
endpoints cloud HTTP sont refusés hors loopback et les requêtes LLM demandent
`store=false`. Un retraitement raté restaure la transcription précédente.

Le runtime RunPod local ajoute `cloud/runpod/start-all.sh` pour superviser les
services voix, nettoyage et LLM séparément, avec token Pod-local aux permissions
strictes, logs privés et arrêt des enfants. `check-services.py` vérifie
uniquement `/v1/models` avec un token lu dans le Pod ; aucun modèle, endpoint ou
engagement ZDR fournisseur n’est inventé. Les tests synthétiques du serveur et
du runtime passent, et le runbook est dans `docs/runpod-runtime.md`.

Le DMG a été régénéré par `./scripts/build-macos.sh`, signé ad hoc, vérifié avec
`codesign --verify --deep --strict`, monté en lecture seule et inspecté.
La matrice de sortie, avec les portes encore externes (Personal Team, compte
RunPod, mTLS/pinning, DPA/ZDR, installateur Windows et validation DPO), est dans
`docs/release-readiness.md`.

Le bundle Mac porte maintenant la version 2.1.0 (build 3) et les trois projets
iOS portent 1.1 (build 2), afin que le durcissement soit identifiable dans les
installations et les diagnostics.

La passerelle agent a ensuite refusé les secrets passés en argument de
processus et ajouté `clean --stdin` / `chat --stdin` pour que les harness ne
mettent pas de texte sensible dans la liste des processus. Les erreurs HTTP
amont distinguent désormais authentification, route absente et panne
relançable ; le `requestId` est propagé au fournisseur sans PHI. La suite agent
passe entièrement (elle compte 9 cas au 25 septembre).

Le dernier passage Mac borne aussi les réponses GPU à 4 MiB, ajoute
`Cache-Control: no-store` et `X-Remote-Scribe-ZDR: required`, et ne remonte plus
le corps arbitraire d’une erreur fournisseur dans l’interface. Le build Swift
et le DMG version 2.1.0 restent verts après ce changement.

Pour éviter de choisir un modèle RunPod à l’intuition, `cloud/runpod/benchmark.py`
fournit maintenant un benchmark synthétique des capacités voix, nettoyage et
LLM. Il envoie seulement un WAV silencieux déterministe de 250 ms et un texte
fixe, borne les réponses à 64 KiB, refuse l’HTTP distant et sort un JSON sans
corps de réponse ni secret. La smoke validation Astra a obtenu 6 réponses 200
sur 3 capacités ; le contrôle de politique `http://gpu.example` renvoie bien
une erreur de configuration (code 2).

Le chemin Windows a ensuite été fermé sans élargir la surface de tests : les
lanceurs `agent/run-windows.ps1` et `server/run-windows.ps1` résolvent Python
3.11+, gardent les secrets dans l’environnement du processus et refusent les
endpoints GPU non HTTPS, les bind wildcard et le mock hors loopback. Le script
`windows/install-runtime.ps1` copie une source minimale hors du checkout, crée
une venv sans index réseau, vérifie l’import de l’agent et peut enregistrer une
tâche planifiée au login ; `uninstall-runtime.ps1` exige son manifeste avant de
supprimer quoi que ce soit. La syntaxe PowerShell n’a pas été exécutée sur le
Mac faute de `pwsh` ; un contrôle statique et la compilation Python ciblée ont
passé. Le déploiement et ses limites sont dans
[`windows-deployment.md`](windows-deployment.md).

Deux archives ont été figées après cette passe, le source complet sans caches
et le paquet Windows ; elles ont passé `unzip -t` et n’embarquaient ni token ni
cache de compilation. Le 25 septembre au soir, la reprise a constaté que
l’empreinte publiée du DMG ne correspondait plus au fichier et que l’archive
source précédait les derniers correctifs. Depuis l’import dans git, ces
artefacts ne sont plus des livrables : ils se reconstruisent depuis le dépôt, et
leurs empreintes ne sont plus recopiées dans la documentation.

### 25 septembre 2026 — revue adversariale produit ciblée

Une revue de chemin critique a identifié deux dérives possibles : le CLI agent
acceptait une URL HTTP distante malgré son rôle loopback, et `serve --mock`
pouvait conserver une URL GPU/LLM héritée de l'environnement. Le correctif
impose HTTPS dès qu'une API agent est distante et rend le profil mock hermétique
à tout endpoint distant. Le contrôle RunPod borne désormais son timeout à 30 s
et marque la sonde `/v1/models` `no-store`/ZDR.

Le client iOS refuse maintenant le TCP sans TLS pour les services découverts
par Bonjour et réserve le mode non chiffré à une connexion manuelle vers
localhost. Cela ferme le cas où une préférence persistée désactivée en test
aurait été réutilisée sur le réseau hospitalier. La revue complète et les
portes externes restantes sont détaillées dans
[`adversarial-product-review-2026-09-25.md`](adversarial-product-review-2026-09-25.md).

Seuls les tests directement liés aux invariants modifiés ont été relancés : 13
tests agent/RunPod et un parse Swift ciblé. Les tests de régression plus larges
restent ceux documentés dans les entrées précédentes.

La même passe a rendu le CLI de transcription plus explicite pour les
harnesses : `.wav`/`.wave` sont envoyés comme WAV, `.pcm`/`.raw` comme PCM
s16le mono 16 kHz avec l'en-tête requis, les extensions ambiguës sont refusées
et les fichiers de plus de 64 MiB ne sont pas lus en mémoire.

Enfin, `check-services.py` peut utiliser un token distinct par capacité
(`VOICE`, `CLEAN`, `LLM`) avant de retomber sur le fichier commun historique,
afin d'éviter de distribuer le même secret à tous les serveurs du Pod.

### 25 septembre 2026 — dépôt public, contrat de séquence, TLS/pinning, CI

**Dépôt.** Le dossier iCloud a été importé dans un dépôt git public
(`MeNass89/voxlocal`) avec une arborescence stable : `ios/`, `RemoteScribe/`,
`mac/VoxLocal/` (whisper.cpp et llama.cpp en sous-modules épinglés), `server/`,
`agent/`, `windows/`, `cloud/runpod/`, `tests/`, `scripts/`, `docs/`,
`website/`. Les artefacts (DMG, archives, fichiers d’empreintes) sont sortis de
la documentation : ils se reconstruisent depuis le dépôt.

**Ce qui a été trouvé.** Deux sondes contre le binaire réel `RemoteScribeHost`
ont montré que l’iPhone ne pouvait pas dicter vers VoxLocal.app :

1. le client iOS numérotait toutes les trames avec un compteur par connexion et
   comptait `framesSent` en chunks, alors que le Core livré numérote seulement
   les chunks audio, à partir de 0 à chaque session, et compte `framesSent` en
   échantillons PCM. Numérotation par connexion : `RemoteScribeError` au premier
   chunk ; numérotation par session : `completed` ;
2. VoxLocal.app écoutait en TCP clair sans code d’appairage, alors que le client
   iOS refusait déjà le clair hors localhost.

**Ce qui a changé.**

- Contrat de séquence aligné sur le Core livré, dans le client iOS et les deux
  hôtes Python ; test d’interopérabilité contre le vrai `RemoteScribeHost`
  (`tests/test_real_host_interop.py`).
- Identité TLS 1.3 sur le Mac (RSA 2048 auto-signé créé au premier lancement,
  importé en mémoire seulement), code d’appairage obligatoire gardé dans le
  trousseau, verrou de 60 s après 5 échecs depuis une même adresse
  (`PairingGate.swift`).
- Épinglage du certificat dans l’app iOS : SHA-256 du certificat DER, feuille de
  confirmation à la première connexion, refus avant tout octet applicatif si
  l’empreinte change.
- Empreinte publiée par les hôtes Python (journal et Bonjour `fp`) ; scripts
  d’identité `scripts/make-tls-identity.sh` et `windows/new-tls-identity.ps1`.
- CI GitHub Actions sur ubuntu, Windows (installateur réellement exécuté) et
  macOS.
- Vague produit : serveur LLM gardé chaud, runtimes arm64, téléchargement des
  modèles et écran d’appairage QR sur Mac (2.3.0) ; onboarding, appairage QR,
  retour de résultat et iPad sur iOS (1.3) ; image RunPod, porte HTTPS et banc
  de mesure (voir `docs/cloud-deployment.md`) ; site produit.
- Revue CodeRabbit 1 (8 majeurs, 10 mineurs corrigés) : plancher macOS 15
  (`kSecImportToMemoryOnly` n’existe qu’à partir de macOS 15 ; avant, l’import
  PKCS#12 peut atterrir dans le trousseau `login`), refus d’un QR code qui
  contredit une empreinte déjà épinglée, `llama-server` vérifié par `lsof` avant
  de recevoir sa clé, code d’appairage jamais en argument pour l’hôte CLI Swift
  hors `--insecure-plaintext`, ACL de la clé privée resserrée sous Windows.

**Ce qui a été vérifié**, depuis la racine du dépôt :

```bash
python3 -m unittest discover -s windows -p 'test_*.py' -v   # 5 OK
python3 -m unittest discover -s tests -p 'test_*.py' -v     # 24 OK
python3 -m unittest discover -s agent -p 'test_*.py' -v     # 9 OK
(cd RemoteScribe && swift test)                             # 8 OK
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
xcodebuild -project ios/RemoteScribePortable.xcodeproj -scheme RemoteScribePortable -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/voxlocal-ios-docs CODE_SIGNING_ALLOWED=NO test   # 8 XCTest
```

CI : run 36127942402 sur le commit `ac5d15c`, quatre jobs verts. La
documentation produit (README, livre blanc sécurité, pitch, FAQ IT, feuille de
route, script de démo) a été réécrite sur ces faits.
