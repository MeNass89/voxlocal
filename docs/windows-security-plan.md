# Windows host, sécurité et ZDR

Ce document décrit le chemin de mise en production du prototype Remote Scribe
pour un poste Windows de l’hôpital. Il s’appuie sur le binaire VoxLocal fourni
et sur le protocole observé dans son exécutable macOS. Il ne prétend pas que le
prototype actuel est déjà conforme : la conformité dépendra aussi du réseau,
du contrat du fournisseur GPU et des procédures de l’hôpital.

## Ce que le binaire établit

Le serveur macOS ouvre un listener TCP sur le port `47365` et publie le service
Bonjour/DNS-SD `_remotescribe._tcp`. La version de protocole est `1` et la taille
maximale d’une trame est `1 MiB`. Le codec attendu est `pcm_s16le`, mono, 16 kHz,
16 bits.

Une trame est codée ainsi (les entiers sont en big-endian) :

```text
uint32 bodyLength
uint8  kind                 # 1 pair, 2 startSession, 3 audioChunk,
                             # 4 stopSession, 5 sessionStatus,
                             # 6 ping, 7 error
char[36] session UUID       # UUID canonique ASCII
uint64 sequence
bytes payload
```

Les payloads JSON utilisent les clés Swift Codable suivantes :

- `PAIR` : `protocolVersion`, `deviceID`, `deviceName`, `pairingCode` ;
- `PAIR` réponse : `accepted`, `serverName`, `selectedBackend`,
  `protocolVersion`, `availableBackends` ;
- `START_SESSION` : `format` (`sampleRate`, `channels`, `bitsPerSample`,
  `codec`), `modeIdentifier`, `language`, `backend` ;
- `SESSION_STATUS` : `state`, `backend`, `bytesReceived`, `message`,
  `transcription`, `rawTranscription`, `finalText`, `audioLocation`,
  `resultLocation` ;
- `ERROR` : `code`, `message`.

Le dépôt contient maintenant [remotescribe_protocol.py](../windows/remotescribe_protocol.py), un encodeur/décodeur Python incrémental qui permet de bâtir le service Windows sans les fichiers Swift `RemoteScribeCore` manquants. Le module est une compatibilité v1 ; il ne chiffre pas le transport.

## Menaces du prototype actuel

Le TCP v1 est en clair. Sur le Wi-Fi ou le VLAN, un poste voisin peut lire les
chunks PCM et les transcriptions, injecter un faux serveur, rejouer un `PAIR`,
envoyer des trames arbitraires ou saturer le serveur. Bonjour ne fournit ni
authentification ni intégrité. Le code d’appairage est un secret partagé statique
et le protocole observé n’a pas de challenge, de limitation d’essais ou de
révocation par appareil.

Le client actuel migre l’historique vers le Keychain `ThisDeviceOnly`, mais l’historique reste une donnée clinique locale. Une politique de rétention et un choix d’activation explicite restent nécessaires avant le pilote.
Le serveur écrit vraisemblablement des WAV et des résultats dans
`remote-scribe/sessions`. Les chemins `audioLocation` et `resultLocation` sont
également des métadonnées sensibles. Les logs, les crash reports et les caches
du moteur doivent être considérés comme des copies potentielles de données de
santé.

Enfin, le mode GPU loué n’est « ZDR » que si le fournisseur garantit par contrat
et par configuration : traitement éphémère, absence de journalisation du
contenu, absence d’entraînement, région de traitement autorisée, chiffrement en
transit et sous-traitant couvert par le DPA de l’hôpital. Un endpoint
`/v1/audio/transcriptions` ou `/v1/chat/completions` présenté comme local ne
suffit pas à lui seul.

## Architecture Windows recommandée

1. **Service** : implémenter un hôte Python asyncio (ou .NET `BackgroundService`)
   qui réutilise le framing du module livré. Une seule session active par
   appareil, un nombre global de connexions limité et une file de traitement
   bornée. Le service doit refuser tout format autre que `pcm_s16le/16000/1/16`.
2. **Découverte** : publier `_remotescribe._tcp` uniquement sur l’interface du
   VLAN clinique. La connexion manuelle reste disponible pour les postes dont
   le DNS-SD est filtré, mais le nom annoncé et le certificat doivent être
   vérifiés par l’application.
3. **Pare-feu** : créer une règle entrante TCP `47365` pour le profil
   `Private`, limitée aux sous-réseaux des appareils autorisés. Ne jamais
   exposer le port au profil `Public`, à Internet ou à une redirection de box.
4. **Compte de service** : utiliser un compte de service dédié ou un virtual
   service account sans privilèges administrateur. Accorder uniquement les ACL
   nécessaires au répertoire de travail ; le service ne doit pas pouvoir
   modifier son propre binaire ni lire les profils utilisateurs.
5. **Secrets** : stocker le code d’appairage, le token GPU et la clé privée dans
   Windows Credential Manager/DPAPI (ou le coffre de l’hôpital), jamais dans un
   `.env`, le registre en clair ou les logs. Le token GPU doit être distinct de
   la clé de chiffrement des données.
6. **Rétention** : traiter le PCM en flux, supprimer le buffer et le WAV
   temporaire dès que la transcription est confirmée, et conserver uniquement
   ce que la politique clinique demande. Appliquer une tâche de purge avec une
   durée explicite et vérifier qu’elle couvre aussi les caches du moteur, les
   fichiers temporaires et les crash dumps.

## Transport à durcir avant des données réelles

Le v1 en clair est acceptable uniquement pour un test contrôlé avec des données
non cliniques. Pour le pilote hospitalier, passer à TLS 1.3 :

- certificat serveur émis par une CA interne, nom prévu dans le DNS-SD et
  **pinning** de la clé publique dans l’app iOS ; désactiver les suites faibles ;
- authentification du client par certificat mTLS provisionné lors de
  l’appairage, ou à défaut challenge-réponse HMAC avec nonce aléatoire, durée de
  vie courte, compteur d’essais et révocation par `deviceID` ;
- conserver le framing v1 à l’intérieur de TLS afin que le serveur Windows et
  les clients puissent migrer progressivement ; annoncer une propriété DNS-SD
  `protocol=2` lorsque le mode TLS est obligatoire ;
- vérifier le compteur `sequence`, refuser tout recul ou doublon et fermer la
  connexion après une erreur de protocole. TLS assure la confidentialité, mais
  ces contrôles empêchent les replays au niveau session.

Si une modification immédiate du client iOS n’est pas possible, utiliser
temporairement un tunnel WireGuard entre le téléphone, le poste Windows et le
VLAN du serveur, avec filtrage strict des pairs. Cela ne remplace pas TLS à
long terme et doit être documenté comme mesure compensatoire.

## Garde-fous de session et d’inférence

- limiter la durée d’une dictée (par exemple 10 minutes) et le volume PCM par
  session ; appliquer une limite indépendante par appareil et par IP ;
- ne jamais accepter un `sessionID` différent de celui créé après
  `START_SESSION` ; refuser `AUDIO_CHUNK` avant l’état `recording` et ignorer
  les chunks après `STOP_SESSION` ;
- borner la taille des chaînes JSON et du nom d’appareil, parser en mode strict
  et ne jamais interpoler un texte dicté dans une commande shell ;
- envoyer au GPU uniquement le flux nécessaire, avec TLS et vérification du
  certificat ; couper les traces de requêtes/réponses et vérifier que le proxy
  ne journalise pas le corps ;
- séparer la transcription brute du texte final. Le LLM de reformulation doit
  recevoir le minimum de contexte clinique et ne doit jamais avoir accès au
  token ou au système de fichiers ;
- retourner au téléphone un texte final explicite, mais éviter de renvoyer des
  chemins locaux (`audioLocation`, `resultLocation`) dans un environnement
  clinique ;
- exposer des métriques agrégées (latence, octets, erreurs) sans contenu,
  identifiants d’appareil complets ni texte dicté.

## Données iOS à corriger

Avant un usage clinique, valider la rétention de l’historique Keychain `ThisDeviceOnly`, désactiver l’inclusion dans les sauvegardes et garder l’action « effacer maintenant ». Ne conserver qu’un
nombre et une durée conformes à la politique de rétention. Le code d’appairage
est déjà placé dans le Keychain, mais il faudra le remplacer par les certificats
ou clés dérivées du nouveau handshake.

## Critères d’acceptation du pilote

- le service refuse toute connexion en provenance du profil réseau Public et
  toute trame de plus de 1 MiB ;
- une capture réseau sur le VLAN ne révèle ni PCM, ni texte, ni token ;
- cinq mauvais codes d’appairage entraînent un back-off et la révocation d’un
  appareil est effective sans redémarrer le service ;
- un arrêt brutal supprime le WAV temporaire et aucune donnée clinique n’est
  présente dans l’Event Log ;
- un test de bout en bout Windows ↔ iOS vérifie fragmentation TCP, coalescence,
  reconnexion, perte réseau et doublon de séquence ;
- le fournisseur GPU fournit le DPA, la région, l’engagement ZDR et une preuve
  de désactivation de l’entraînement/logging avant toute donnée patient ;
- la journalisation et les procédures d’incident sont validées par le DPO et la
  sécurité de l’hôpital.

