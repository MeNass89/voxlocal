# VoxLocal / Remote Scribe — journal de reconstruction

> Document de traçabilité pour les prochains modèles et contributeurs. Chaque décision est liée à une preuve ou marquée comme hypothèse.

## 2026-09-24 — point de départ

### Objectif produit

Le prototype sert à un hôpital : l'iPhone est un microphone distant, le Mac ou un hôte Windows reçoit les trames audio sur le réseau local, puis exécute une inférence locale ou sur un GPU privé loué. Le serveur annonce le moteur `voxlocal` (nom Swift `voxLocal`) et peut conserver `superwhisper` pour compatibilité.

Contraintes retenues :

- ZDR : l'audio et les transcriptions ne doivent pas être conservés par défaut ; les journaux ne doivent jamais contenir le contenu clinique.
- RGPD : minimisation, traçabilité technique, chiffrement en transit en mode production, appairage explicite et rétention configurable.
- Prototype exploitable : conserver une compatibilité avec le protocole TCP existant avant d'introduire une rupture de version.
- Windows : le service hôte doit pouvoir tourner sans dépendre de SwiftUI ou de macOS.

### Preuves disponibles

- `PortableClient.zip` contient l'app iOS et son projet Xcode, mais pas `Core/Sources`.
- `VoxLocal.dmg` contient `VoxLocal.app` (version 2.0.0, binaire x86_64) et les runtimes `whisper-cli` et `llama-cli`.
- Les symboles Swift et les chaînes du binaire permettent de récupérer les noms de types, propriétés, états et constantes du protocole.
- Le binaire confirme les endpoints GPU compatibles OpenAI : `/v1/audio/transcriptions`, `/v1/chat/completions`, `/v1/models`.

### Constantes récupérées par rétro-ingénierie

- Service Bonjour : `_remotescribe._tcp`.
- Port TCP par défaut : `47365` (`0xB905` dans le getter Swift).
- Version protocole : `1`.
- Taille maximale d'une trame : `1_048_576` octets.
- Audio accepté : PCM signé 16 bits, mono, 16 kHz.
- Backend enum : Swift case `voxLocal`, JSON raw value `voxlocal`, plus `superwhisper`.
- États réseau : `ready`, `recording`, `processing`, `completed`, `failed`. `paired` est un état interne possible, jamais une valeur wire.
- Types de message, dans l'ordre des `allCases` : `pair`, `startSession`, `audioChunk`, `stopSession`, `sessionStatus`, `ping`, `error`.
- Champs JSON récupérés : `protocolVersion`, `deviceID`, `deviceName`, `pairingCode`, `accepted`, `serverName`, `selectedBackend`, `availableBackends`, `format`, `modeIdentifier`, `language`, `backend`, `framesSent`, `state`, `bytesReceived`, `message`, `transcription`, `rawTranscription`, `finalText`, `audioLocation`, `resultLocation`, `timestamp`, `code`.

### Format de trame déduit

Le décodeur lit un entier non signé 32 bits big-endian en tête. Cette longueur compte le corps qui suit. Le corps est :

```text
uint32_be bodyLength
uint8    messageKind (1..7)
utf8[36] UUID canonique de session
uint64_be sequence
bytes    payload
```

La preuve du big-endian est la boucle `value = value << 8 | byte` dans `readUInt32` et `readUInt64`. Le code encode l'UUID en UTF-8 et vérifie une longueur exacte de 36 octets.

### Choix d'implémentation

1. Reconstituer un `Core/Sources` Swift minimal et compatible avec l'API appelée par `PortableClientModel.swift`.
2. Ajouter une implémentation Python asyncio du même protocole pour Windows et les tests d'interopérabilité.
3. Faire du mode ZDR la valeur par défaut du serveur Python : pas de fichier audio, pas de transcription persistée, logs structurés sans contenu.
4. Garder un mode TCP brut uniquement pour les tests synthétiques explicitement marqués ; exiger TLS 1.3 côté serveur dès qu’un endpoint GPU est configuré.
5. Améliorer l'interface SwiftUI autour de la confiance opérationnelle : statut de confidentialité visible, erreurs actionnables, états de connexion et d'enregistrement distincts, accessibilité et iPad.

### Limites connues

- Le code serveur Swift d'origine n'est pas dans les artefacts. Les structures et la trame sont récupérées avec forte confiance ; les détails internes des backends et du traitement GPU restent à réimplémenter.
- La confiance TLS du client iOS n'est pas présente dans le prototype fourni. Le serveur Windows sera donc livré avec une configuration TLS, mais l'intégration iOS sécurisée nécessitera une évolution coordonnée du `RemoteScribeClient`.
- Aucun modèle médical ni clé GPU n'est embarqué. Le serveur fournit un adaptateur OpenAI-compatible et un mode mock pour les tests.

## Méthode de travail

Pour chaque modification :

1. Formuler l'hypothèse dans ce journal ou dans le rapport associé.
2. Modifier une surface petite et isolée.
3. Vérifier par compilation, tests de protocole, ou test d'intégration simulé.
4. Conserver le changement uniquement si la vérification progresse ; noter les échecs et les limites.
