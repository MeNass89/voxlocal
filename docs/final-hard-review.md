# Revue adversariale finale — Remote Scribe / VoxLocal

Date de revue : 2026-09-24  
Périmètre : `ios/Core/Sources`, `ios/RemoteScribePortable`, `windows/`, `server/`, documentation sécurité et protocole.

Cette revue vérifie la compatibilité wire reconstruite, les invariants de session, les propriétés ZDR, le transport Windows/iOS et la cohérence entre les affirmations de la documentation et le code. Elle ne constitue pas une homologation RGPD ou une validation DPO.

## Résultat exécutif

Le protocole de tramage est cohérent entre le codec Swift et `windows/remotescribe_protocol.py` : longueur big-endian, UUID ASCII canonique, séquence UInt64 et limite de trame à 1 MiB. Les tests d'intégration simulés couvrent l'appairage, le démarrage, un chunk audio et l'arrêt.

Un défaut d'intégrité de session a été corrigé pendant cette revue : l'hôte Windows de référence acceptait un `STOP_SESSION` sans lire ni vérifier `framesSent`. Il pouvait donc considérer comme valide une session dont le nombre de chunks déclaré par le client était faux. Le correctif valide le JSON, rejette les booléens (qui sont des `int` en Python), compare exactement le nombre de chunks reçus et vérifie que le premier `PAIR` est bien en séquence zéro et en protocole v1.

Le projet reste un prototype. Les points P0 ci-dessous doivent être fermés avant toute donnée de santé réelle.

## Correctif appliqué

- `windows/remotescribe_host.py`
  - `ActiveSession.frames_received` ajouté et incrémenté pour chaque `AUDIO_CHUNK`.
  - `STOP_SESSION.framesSent` parsé et comparé exactement à ce compteur.
  - `PAIR.protocolVersion == 1` et `PAIR.sequence == 0` imposés.
- `windows/test_remotescribe_host.py`
  - scénario de non-concordance du nombre de chunks ajouté ; le serveur renvoie `protocolViolation`.
- `ios/Core/Sources/RemoteClient.swift` et `FrameCodec.swift`
  - état réseau et compteurs sérialisés sur la queue de transport ; file d'envoi bornée ; STOP est ordonné après les chunks ; sessions terminales et décodeur réinitialisés ; EOF explicite ; callbacks d'une génération précédente ignorés.
- `tests/test_swift_core.py` et `tests/swift_core_regression.swift`
  - peer socket indépendant qui vérifie deux sessions, 20 producteurs audio concurrents, les séquences et le rejeu après STOP, puis une reconnexion après trame tronquée.
- `ios/RemoteScribePortable/AudioStreamer.swift` et `PortableClientModel.swift`
  - drain audio avant STOP, timeouts de transition, reconnexion protégée contre les callbacks obsolètes, historique Keychain opt-in et connexion Bonjour non automatique.

Vérification : 5 tests Windows, 6 tests serveur et 2 tests Core Swift passent ; compilation Python par `py_compile` et `swiftc -typecheck` passées.

## Findings classés

### P0 — Bloquants avant PHI

#### P0-1 — Le transport sécurisé est optionnel et le pinning annoncé n'existe pas

Preuves :

- `ios/Core/Sources/RemoteClient.swift` accepte encore `tls: false`, mais `PortableClientModel` ne l'autorise que vers localhost (`isLoopbackHost`) et exige TLS pour tout poste découvert par Bonjour. En TLS, le client compare le SHA-256 du certificat feuille à l'empreinte épinglée dans le trousseau ; sans empreinte, il accepte un certificat reconnu par le trust store système et propose sinon une validation TOFU de l'empreinte. Aucun certificat client mTLS n'est configuré.
- `server/voxlocal_server.py` exige désormais TLS pour un backend GPU et peut demander une CA client avec `--tls-client-ca`. Le pinning iOS est implémenté ; l'empreinte doit être provisionnée (lien QR) ou validée en TOFU, et le certificat client mTLS reste à provisionner.
- `windows/remotescribe_host.py:416-418` est explicitement plaintext.

Impact : toute connexion lancée en mode plaintext expose l'audio et les transcriptions et permet un faux serveur sur le VLAN. En TLS avec une CA gérée, la confidentialité et l'identité serveur sont assurées par le système ; l'absence de pinning et de certificat client réduit cependant la résistance à une CA compromise et ne correspond pas au profil mTLS précédemment décrit.

Patch recommandé :

1. Définir un profil transport explicite (plaintext uniquement test local, TLS obligatoire en pilote).
2. Faire échouer le serveur si TLS est requis mais absent ; charger la CA interne et vérifier le nom DNS du serveur.
3. Côté iOS, garder la validation du trust store géré et ajouter un pin de clé publique si le modèle MDM le permet ; réserver le mTLS à un profil d'enrôlement renforcé.
4. Ajouter un test négatif : certificat serveur non approuvé, nom DNS incorrect et mode plaintext en profil pilote doivent échouer.

Mesure compensatoire documentée : VLAN clinique filtré ou WireGuard pair-à-pair, données non cliniques uniquement tant que ce P0 n'est pas fermé.

État 2026-09-25 : identité TLS serveur, pinning iOS TOFU et code d’appairage obligatoire livrés ; mTLS/enrôlement MDM restent une porte pilote. Le serveur Swift et l’hôte Python imposent TLS 1.3 ; le client iOS n’accepte le clair que vers loopback ; un QR code ne remplace jamais une empreinte déjà épinglée. VoxLocal exige macOS 15 pour importer l’identité TLS en mémoire seulement (`kSecImportToMemoryOnly`).

#### P0-2 — « ZDR » n'est pas une propriété démontrée du GPU loué

Preuves :

- `server/voxlocal_server.py:148-199` envoie le WAV au GPU et peut enchaîner une reformulation LLM ; aucune preuve locale ne contrôle journaux, caches, snapshots, rétention ou entraînement du fournisseur.
- Le serveur de référence envoie désormais `X-Remote-Scribe-ZDR: required`, désactive les proxies d’environnement implicites et refuse les redirections ; ces mesures restent des signaux locaux et ne prouvent pas le comportement du fournisseur.
- Les docs reconnaissent que le header est seulement un signal et que le DPA/région/rétention doivent être vérifiés.

Patch recommandé : obtenir un DPA et une fiche de configuration du fournisseur (rétention zéro, pas d'entraînement, région, sous-traitants, chiffrement, journaux), tester par inspection de compte et documenter l'ID de configuration. Traiter toute réponse de conformité absente comme un échec de déploiement.

#### P0-3 — Contrôle d'accès trop faible pour un réseau hospitalier

Le pairing code reste un secret statique transporté dans le protocole v1, sans challenge, expiration ni révocation d'appareil. Le serveur canonique ajoute désormais rate limiting et plafonds de connexions ; l'hôte legacy n'offre pas le même niveau de garde-fous.

Patch recommandé : enrôlement par appareil, nonce/challenge signé ou mTLS, rotation/révocation, rate limiting global et par appareil, limite de connexions et métriques d'abus. Conserver le pairing code uniquement pour bootstrap local contrôlé.

État 2026-09-25 : le code d’appairage est obligatoire sur tous les hôtes et ne circule que dans TLS. Le serveur Swift bloque une adresse 60 s après 5 échecs dans une fenêtre de 10 minutes sans affecter les autres appareils (`RemoteScribe/Core/Sources/PairingGate.swift`, testé) ; l’hôte Python refuse une adresse qui compte 5 échecs en 60 s. L’enrôlement par appareil, la rotation et la révocation individuelle restent ouverts.

### P1 — Risques élevés de stabilité ou d'interopérabilité

#### P1-1 — Deux hôtes Python implémentent des contrats différents — traité par séparation explicite

`windows/remotescribe_host.py` et `server/voxlocal_server.py` ont des limites et comportements différents (durée, taille PCM, messages d'erreur, TLS, publication Bonjour, backends). Le premier ne publie pas Bonjour et le second publie seulement si `zeroconf` est installé et si l'adresse n'est pas wildcard. Le nom « hôte Windows » recouvre donc deux services non équivalents.

État : `server/voxlocal_server.py` est maintenant l’implémentation de référence ; `windows/remotescribe_host.py` est documenté et réservé aux tests synthétiques.

#### P1-2 — Séquence initiale et re-appairage : corrigés côté serveur canonique

`server/voxlocal_server.py` exige désormais `sequence == 0` pour le premier `PAIR`, la contiguïté de toutes les trames et refuse tout `PAIR` après appairage. Les tests de rejeu/offset initial doivent rester dans la matrice de non-régression.

#### P1-3 — Limites de connexions et d'inférence : corrigées côté serveur canonique

Le serveur canonique applique des plafonds globaux/par IP, des timeouts d'appairage, d'inactivité et de chunks, ainsi qu'une limite d'inférences concurrentes. L'hôte legacy `windows/remotescribe_host.py` ne possède pas tous ces garde-fous et doit rester réservé aux tests.

Action : ne distribuer que le serveur canonique et tester les limites sous charge contrôlée.

#### P1-4 — Backpressure et annulation

Le client Swift sérialise désormais l'envoi sur sa queue, ordonne STOP après les chunks et limite sa file à 1 MiB. Le serveur canonique borne les connexions et les inférences ; une annulation native du backend lors d'une déconnexion reste à étudier pour éviter qu'un appel HTTP déjà parti ne termine en dehors de la session.

#### P1-5 — Mémoire audio doublée pendant l'inférence

À l'arrêt, les deux implémentations convertissent le `bytearray` en `bytes` avant l'appel au backend. Le buffer original reste vivant jusqu'à la fin de la coroutine/thread ; pendant cette période deux copies du PCM existent (et le multipart WAV ajoute une troisième copie côté GPU).

Action : plafonner strictement durée et octets (valeurs validées par politique clinique), éviter les copies inutiles, effacer les buffers dans un `finally` documenté et surveiller le pic mémoire. Ce point est surtout une disponibilité et une minimisation de données, pas une garantie d'effacement physique Python.

### P2 — À corriger avant pilote élargi ou à valider en environnement hospitalier

#### P2-1 — Documentation `paired` — corrigé

`docs/decision-log.md` liste `paired` parmi les états récupérés, alors que `docs/protocol-reconstruction.md` précise qu'il n'existe pas de valeur réseau `paired` et que `RemoteSessionState` contient cinq états. Le code Swift confirme cinq cas.

État : le journal indique maintenant explicitement que `paired` est interne et absent du wire.

#### P2-2 — Portée de l'affirmation ZDR — corrigé dans le code et les docs

État : les documents parlent désormais de « pas de persistance applicative locale » ; le DPA, la région et les caches du fournisseur restent à vérifier.

#### P2-3 — Migration des préférences TLS existantes

`PortableClientModel.useTLS` est activé par défaut pour les nouvelles installations. Le serveur refuse le plaintext sauf profil mock explicitement marqué ; les installations existantes peuvent conserver une préférence historique désactivée.

Action : migrer ou invalider cette préférence dans le build pilote et afficher un blocage explicite si le client tente un transport non chiffré.

#### P2-4 — Découverte Bonjour non authentifiée — connexion automatique supprimée

Le TXT record `backend/backends/version` reste informatif et contrôlable par tout hôte du réseau. Le client n’ouvre plus automatiquement une découverte Bonjour : l’opérateur sélectionne le serveur et saisit le code.

Action : afficher le serveur réellement appairé et ajouter le pin de certificat lors du provisioning MDM ; ne pas considérer Bonjour comme une preuve d'identité.

## Invariants vérifiés

- trame : longueur BE, corps minimum 45, maximum 1 MiB ;
- UUID : 36 caractères ASCII et session zéro pour PAIR ;
- audio : PCM signé 16 bits, chunks de taille paire, format 16 kHz mono côté START ;
- session : UUID constant, séquences contiguës après START, quotas durée/octet ;
- arrêt : `framesSent` désormais égal au nombre reçu dans l'hôte Windows de référence ;
- Persistance applicative : aucun WAV ou texte local côté serveur par défaut ; l’historique iOS est mémoire seule sauf opt-in Keychain ;
- client Swift : compteurs client et serveur remis à zéro entre sessions, séquences entrantes vérifiées, EOF signalé, callbacks d'ancienne connexion ignorés ;
- logs : les messages de haut niveau n'impriment pas le texte dicté.

## Vérifications exécutées

État au 25 septembre 2026, depuis la racine du dépôt :

```text
python3 -m unittest discover -s windows -p 'test_*.py' -v   # 5 OK
python3 -m unittest discover -s tests -p 'test_*.py' -v     # 24 OK (dont Core Swift, fixture TLS avec épinglage, interop RemoteScribeHost)
python3 -m unittest discover -s agent -p 'test_*.py' -v     # 9 OK
(cd RemoteScribe && swift test)                             # 8 OK
(cd mac/VoxLocal && swift build -c release --product VoxLocal)   # OK
xcodebuild … -sdk iphonesimulator … test                    # 8 XCTest OK (RemoteScribePortableTests)
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build   # OK
```

La CI GitHub Actions (run 36127942402, commit `ac5d15c`) exécute ces suites sur ubuntu, Windows et macOS : quatre jobs verts. Le test TLS réel sur un iPhone physique et dans un réseau hospitalier reste à faire.

## Décision de mise en service

Le prototype peut être utilisé pour interopérabilité et données synthétiques sur localhost ou VLAN filtré. Il ne doit pas être présenté comme RGPD-compliant pour PHI tant que P0-1, P0-2 et P0-3 ne sont pas fermés et validés par le DPO/la sécurité de l'hôpital.
