# Architecture

```text
[iPhone / iPad]  ios/ (RemoteScribePortable + ios/Core)
  AVAudioEngine -> PCM S16LE 16 kHz -> Remote Scribe v1
  appairage : QR code (nom, code, empreinte) ou saisie manuelle
                                           |
                     TLS 1.3, port 47365, certificat épinglé (SHA-256 du DER)
                                           |
                                           v
                              [Poste hôte : macOS ou Windows]
                              mac/VoxLocal + RemoteScribe/Core (macOS 15+)
                              server/ (Python, Windows/macOS)
                              code d'appairage + verrou 5 échecs / 60 s
                              machine d'état de session
                                           |
                  +------------------------+-------------------------+
                  |                                                  |
          local (Mac)                                      GPU privé (option)
          whisper-cli                                      HTTPS + jeton
          llama-server 127.0.0.1 (clé aléatoire)           /v1/audio/transcriptions
          repli llama-cli                                  /v1/chat/completions
                  |
          texte collé dans l'application active du poste

[Harness d'agent local]
  -> voxlocal-agent-api (127.0.0.1:47366, Bearer, JSON)
  -> voice / clean / llm HTTPS séparés
  -> RunPod privé après validation DPA/ZDR
```

Le contenu clinique ne quitte pas le périmètre contrôlé de l’hôpital, sauf vers
le GPU privé si l’établissement l’active. Les hôtes Python ne persistent rien ;
VoxLocal sur Mac garde un historique local des dictées dans le compte de
l’utilisateur. Les journaux portent des identifiants, des tailles et des états,
jamais le texte ou l’audio. Le détail est dans
[`security-whitepaper.md`](security-whitepaper.md).

Correspondance avec le dépôt : `ios/` contient le client iPhone/iPad et sa copie
durcie du client Core (`ios/Core/Sources`) ; `RemoteScribe/Core/Sources` est le
Core livré, source de vérité du contrat wire ; `mac/VoxLocal/` est l’app macOS
qui embarque ce Core ; `server/` est l’hôte Python de référence ; `agent/` est
l’API loopback ; `cloud/runpod/` est le runtime GPU privé (déploiement :
`docs/cloud-deployment.md`).
