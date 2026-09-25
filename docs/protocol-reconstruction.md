# Reconstruction du protocole RemoteScribe v1

Ce document fixe le contrat observable entre le client portable, le serveur
RemoteScribeCore livré avec VoxLocal et le serveur Windows de ce dépôt. Il a été
reconstruit à partir du projet présent dans `PortableClient.zip`, des références
Xcode et du binaire macOS contenu dans `VoxLocal.dmg` (VoxLocal 2.0.0,
`RemoteScribeCore` ; image d’origine fournie avec le prototype, hors dépôt). Les
éléments marqués « déduit » viennent des chemins d'exécution du binaire et
doivent être gardés comme hypothèses testables lors d'un test d'interopérabilité.

## Blocage initial et éléments observés

Le projet Swift portable fourni dans l'archive ne compile pas seul. Son
`project.pbxproj` référence trois fichiers en dehors de l'archive :

```
../Core/Sources/RemoteProtocol.swift
../Core/Sources/FrameCodec.swift
../Core/Sources/RemoteClient.swift
```

Ces fichiers étaient absents de `PortableClient.zip`. Le README confirme que le
serveur attend un flux TCP RemoteScribeCore, le service Bonjour
`_remotescribe._tcp`, le port 47365 et les messages PAIR, START_SESSION,
AUDIO_CHUNK, STOP_SESSION et SESSION_STATUS. Le binaire est un Mach-O x86_64
qui exporte les symboles `RemoteFrameEncoder`, `RemoteFrameDecoder`,
`RemoteScribeClient`, `RemoteScribeBrowser`, `RemoteSessionHandler` et tous les
types de payload décrits ci-dessous.

## Trame TCP (exact)

TCP est un flux : un `read` peut couper une trame ou en contenir plusieurs. Le
décodeur accumule donc les octets et retire les trames complètes dans l'ordre.
Tous les entiers sont non signés et big-endian.

```
offset  taille  contenu
0       4       bodyLength (UInt32 BE), exclut ces 4 octets
4       1       kind (UInt8, valeurs 1..7)
5       36      sessionID : UUID.uuidString UTF-8/ASCII (36 caractères, hexadécimal majuscule à l'encodage)
41      8       sequence (UInt64 BE)
49      n       payload brut (JSON UTF-8 pour les messages de contrôle)
```

La longueur minimale du corps est 45 (en-tête interne sans payload) et la
longueur maximale est exactement 1 048 576 octets (`maximumFrameSize`). La
trame complète fait donc `4 + bodyLength`. Une longueur hors limites, un kind
inconnu ou un UUID qui ne passe pas `UUID(uuidString:)` est rejeté. Le UUID
zéro (`00000000-0000-0000-0000-000000000000`) est `RemoteFrame.noSession`.

L'encodeur écrit le raw kind, le texte UUID, puis la séquence. Le binaire
encode le payload sans compression ni chiffrement. `RemoteFrame.json` appelle
un `JSONEncoder` Foundation standard et `RemoteFrame.decode` un
`JSONDecoder` standard : aucun `sortedKeys`, snake case ou stratégie de date
n'est configuré dans le binaire expédié. Les optionnels synthétisés par
`Codable` sont absents du JSON lorsqu'ils valent `nil`.

## Kind et constantes

Le stockage interne de `RemoteMessageKind` est un index Swift 0..6 ; son
getter `rawValue` ajoute 1. Les valeurs réseau et leur sens sont :

| réseau | kind Swift | sens |
|---:|---|---|
| 1 | `pair` | demande/réponse d'appairage |
| 2 | `startSession` | ouverture d'une dictée |
| 3 | `audioChunk` | PCM brut |
| 4 | `stopSession` | fin d'envoi audio |
| 5 | `sessionStatus` | état et résultat côté serveur |
| 6 | `ping` | sonde de connexion |
| 7 | `error` | erreur encodée |

Constantes confirmées dans le binaire : `version = 1`, `defaultPort = 47365`,
`maximumFrameSize = 1_048_576`, `serviceType = "_remotescribe._tcp"`.

Les deux backends et leurs **raw values exacts** sont :

```
RemoteBackendKind.voxLocal    = "voxlocal"
RemoteBackendKind.superwhisper = "superwhisper"
```

Le nom Swift peut rester `voxLocal`, mais il faut expliciter la raw value
`"voxlocal"`; la valeur synthétisée `"voxLocal"` n'est pas compatible avec le
binaire. `RemoteAudioFormat.isSupported` n'accepte que
`sampleRate=16000`, `channels=1`, `bitsPerSample=16`, `codec="pcm_s16le"`.
`bytesPerSecond` vaut `sampleRate * channels * bitsPerSample / 8`.

`RemoteSessionState` est une enum String de **cinq** cas, dans cet ordre de
stockage (ordre utile uniquement si un code reproduit le binaire) :

```
index 0: failed
index 1: recording
index 2: processing
index 3: ready
index 4: completed
```

Il n'existe pas de valeur réseau `paired` dans la version livrée.

## Payloads JSON Codable

Les clés sont les noms Swift ci-dessous et leur casse est significative.

| type | champs dans l'ordre déclaré |
|---|---|
| `PairRequest` | `protocolVersion: Int`, `deviceID: String`, `deviceName: String`, `pairingCode: String?` |
| `PairResponse` | `accepted: Bool`, `serverName: String`, `selectedBackend: RemoteBackendKind`, `protocolVersion: Int`, `availableBackends: [RemoteBackendKind]?` |
| `StartSessionRequest` | `format: RemoteAudioFormat`, `modeIdentifier: String?`, `language: String?`, `backend: RemoteBackendKind?` |
| `StopSessionRequest` | `framesSent: UInt64` |
| `SessionStatusPayload` | `state: RemoteSessionState`, `backend: RemoteBackendKind`, `bytesReceived: UInt64`, `message: String?`, `transcription: String?`, `rawTranscription: String?`, `finalText: String?`, `audioLocation: String?`, `resultLocation: String?` |
| `PingPayload` | `timestamp: Double` |
| `RemoteErrorPayload` | `code: String`, `message: String` |

`RemoteScribeSession` est un modèle serveur (UUID, appareil, URL audio,
format, mode, langue, dates et `bytesReceived`) et ne doit pas être envoyé au
client. Les données audio sont le payload brut d'un kind 3, pas du JSON ni du
Base64.

## Séquence et états attendus

Contrat canonique (source de vérité : `RemoteScribe/Core/Sources`) :

- `sequence` is meaningful only on AUDIO_CHUNK frames: per session, first chunk 0, strictly contiguous. On every other frame (PAIR, START_SESSION, STOP_SESSION, PING, SESSION_STATUS, ERROR) the sender writes 0 and the receiver ignores the field.
- `StopSessionRequest.framesSent` = total PCM sample frames of the session = `bytesReceived / 2` (mono, 16-bit). Servers reject a STOP whose `framesSent` differs from `bytesReceived / 2` with `protocolViolation`. The finalized WAV of a rejected session is kept on disk so the operator can retry the dictation from VoxLocal history.
- PAIR must be the first frame of a connection, with session UUID `00000000-0000-0000-0000-000000000000`; a second PAIR is a protocol violation. START_SESSION before PAIR is `notPaired`.

Correction du 2026-09-25 : la reconstruction initiale affirmait que le client
incrémentait une séquence globale pour chaque frame envoyée et comptait les
chunks dans `framesSent`. C'était faux. Le source livré le prouve :
`RemoteClient.swift` remet `sequence = 0` dans `startSession`, ne numérote que
les `AUDIO_CHUNK`, envoie 0 sur toutes les autres frames et compte
`framesSent += bytes / 2`; côté serveur, `WAVRemoteAudioReceiver` ne vérifie
que la contiguïté des chunks audio de la session et `RemoteSessionHandler`
envoie toutes ses frames avec la séquence 0. Une sonde contre le binaire
`RemoteScribeHost` compilé l'a confirmé : numérotation globale → erreur au
premier chunk audio; numérotation par session → `completed`. Le client iOS et
les deux hôtes Python suivent désormais ce contrat, vérifié par
`tests/test_real_host_interop.py`.

1. Le client ouvre TCP et envoie `PAIR` (séquence 0) avec
   `sessionID=noSession`, `PairRequest.protocolVersion=1` et, si nécessaire,
   le code d'appairage.
2. Le serveur refuse toute autre kind avant PAIR. En cas d'acceptation il
   renvoie une `PairResponse` (kind `pair`) puis un `SessionStatusPayload` de
   `ready` avec `noSession`. Le code d'appairage est comparé avant de créer une
   session; un mauvais code produit l'erreur localisée « code d'appairage
   incorrect ».
3. `START_SESSION` porte un nouvel UUID et `StartSessionRequest`. Le serveur
   exige le format PCM ci-dessus, refuse une seconde session active, sélectionne
   `backend` demandé ou le backend par défaut et commence à recevoir.
4. `AUDIO_CHUNK` réutilise l'UUID de la session et transporte les échantillons
   PCM little-endian. Le récepteur WAV commence à la séquence 0 et exige des
   séquences contiguës au sein de la session (une répétition ou un saut est
   une erreur). Le client remet son compteur audio à 0 à chaque
   `START_SESSION` et compte les échantillons PCM (`octets / 2`) dans
   `StopSessionRequest.framesSent`.
5. `STOP_SESSION` (séquence 0) contient le nombre d'échantillons PCM envoyés.
   Le serveur termine le WAV, rejette le STOP si `framesSent` diffère de
   `bytesReceived / 2`, sinon publie `processing`, puis publie `completed` avec les textes/chemins
   disponibles, ou `failed` avec `message`. La réception d'un kind 5 côté
   client est donc un callback `(sessionID, SessionStatusPayload)`.
6. `PING` utilise normalement `noSession` et `PingPayload.timestamp`; le
   serveur répond par un ping. Un kind serveur inattendu, une session absente
   ou un UUID différent de la session active est une erreur. À la déconnexion,
   le serveur ferme le récepteur et efface le backend actif.

Le client portable appelle au minimum :

```
connect(to: NWEndpoint, deviceID: String, deviceName: String, pairingCode: String?)
connect(host: String, port: UInt16, deviceID: String, deviceName: String, pairingCode: String?)
startSession(format: RemoteAudioFormat, modeIdentifier: String?, language: String?, backend: RemoteBackendKind?) -> UUID
sendAudio(Data)
stopSession()
abandonSession(); disconnect(); ping()
```

Les propriétés de callback attendues sont `onStateChanged`, `onPairResponse`,
`onSessionStatus` et `onError`. `RemoteScribeBrowser` annonce et découvre le
service Bonjour et remonte `DiscoveredRemoteScribeServer(name, endpoint,
availableBackends, protocolVersion)`.

## Bonjour et métadonnées

Le binaire lit le TXT record Bonjour avec les clés `backends` (liste séparée
par des virgules de `voxlocal,superwhisper`), `backend` (backend par défaut) et
`version` (entier). L'absence de TXT ne rend pas le service invalide; le PAIR
reste l'autorité pour la liste réelle. Le serveur doit publier le type
`_remotescribe._tcp` sans ajouter `.local` à la valeur de type.

## Points de vigilance pour l'implémentation Windows

Le protocole expédié est un TCP **en clair**. Le code d'appairage authentifie
le client mais ne fournit ni confidentialité ni intégrité et le binaire ne
contient pas de TLS. Pour des données hospitalières, le prototype doit rester
sur un VLAN/VPN et un pare-feu restrictif; une version de production doit
ajouter TLS 1.3 avec validation/pinning côté client, ou placer le service
derrière un tunnel authentifié. Les journaux et les réponses d'erreur ne
doivent pas contenir le PCM ni la transcription.

Enfin, ne pas confondre la taille maximale d'une **trame** (1 MiB) avec la
taille totale d'une dictée : chaque chunk doit être fragmenté sous cette limite
et les limites de durée/mémoire du serveur sont une politique d'application,
pas un champ du protocole v1.
