# Architecture cible

```text
[iPhone / iPad]
  AVAudioEngine -> PCM S16LE 16 kHz -> Remote Scribe TCP/TLS
                                           |
                                           v
                              [VoxLocal Host: macOS ou Windows]
                              pairing + session state machine
                                           |
                  +------------------------+-------------------------+
                  |                                                  |
          local whisper.cpp                                 GPU privé ZDR
          whisper-cli / llama-cli                 /v1/audio/transcriptions
                                                  /v1/chat/completions

[Harness d'agent local]
  -> voxlocal-agent-api (127.0.0.1:47366, Bearer, JSON)
  -> voice / clean / llm HTTPS séparés
  -> RunPod privé après validation DPA/ZDR
```

Le contenu clinique ne quitte le périmètre contrôlé de l'hôpital ou du GPU privé. L'hôte ne doit écrire dans `sessions/` qu'en mode diagnostic explicitement activé. Les logs portent des identifiants, des tailles et des états, jamais le texte ou l'audio.
