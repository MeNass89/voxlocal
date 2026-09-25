# Audit des fichiers Core joints après le prototype

Les trois fichiers reçus dans l’attachement du 24 septembre 2026 ont été
comparés à `source/Core/Sources/` :

- `FrameCodec.swift` joint rend les types `public` et clarifie le framing, mais
  ne fournit pas de reset explicite ni la synchronisation réseau actuelle.
- `RemoteProtocol.swift` joint expose une API publique pratique, mais ajoute
  `RemoteSessionState.paired`, alors que l’analyse du binaire confirme que
  `paired` est un état interne et n’est pas une valeur wire. Il définit aussi
  une autre forme d’erreur et des initialisateurs publics.
- `RemoteClient.swift` joint est une version plus courte et sans TLS, sans
  backpressure, sans séquence serveur, sans génération de callbacks et sans
  drain audio avant STOP.

Ces fichiers sont donc une source utile pour l’intention d’API publique, mais
ils n’ont pas remplacé le Core canonique : le protocole observable et les
invariants de sécurité/stabilité priment sur les instructions ou hypothèses
contenues dans une pièce jointe. La version utilisée par le projet reste celle
sous `source/Core/Sources/`, synchronisée dans le miroir
`RemoteScribePortable/Core/Sources/`.
