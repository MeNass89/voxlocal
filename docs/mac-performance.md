# Performances de VoxLocal sur Mac

VoxLocal 2.3.0 (build 5) transcrit avec `whisper-cli` et réécrit avec un `llama-server` gardé chaud. Les deux runtimes viennent du dépôt (`mac/VoxLocal/Vendor/src`) et sont compilés pour ce Mac.

## Mesure

Script : `scripts/bench-mac-inference.sh <modèle-whisper.bin> <modèle.gguf> [note]`. Résultat : `docs/superpowers/evidence/2026-09-25-mac-bench.json`.

Le script produit une dictée française synthétique de 19,8 s (`say -v Thomas`, convertie en WAV 16 kHz mono s16le comme les enregistrements de l’app). Il exécute ensuite trois fois chaque étape avec les runtimes de `Vendor/bin` :

1. Whisper, avec les options de `WhisperEngine`.
2. La réécriture du mode « Medical », avec l’invite système exacte de `DictationPipeline`, par un `llama-cli` lancé à chaque dictée (le chemin d’avant 2.3.0).
3. La même réécriture par un `llama-server` démarré une seule fois (le chemin de 2.3.0).

Mesure du 25 septembre 2026, Apple M2, 8 cœurs, 16 Go, macOS 27.0 :

| Étape | p50 |
|---|---|
| Transcription Whisper, 19,8 s d’audio | 0,657 s |
| Réécriture Medical, `llama-cli` à froid | 2,048 s |
| Réécriture Medical, `llama-server` chaud | 1,203 s |
| Démarrage de `llama-server`, une fois par modèle | 0,547 s |

Sur ce Mac, avec ces modèles, le serveur chaud rend la réécriture 1,70 fois plus rapide. La deuxième dictée ne recharge plus le modèle.

**Limite de cette mesure.** Aucun modèle n’était installé dans `~/Library/Application Support/VoxLocal/models/`. La mesure utilise donc les plus petits modèles disponibles : `ggml-tiny.bin` et `qwen2.5-0.5b-instruct-q4_k_m.gguf`. Ils ont été téléchargés dans `/tmp` et ne sont pas dans le dépôt. La transcription de tiny n’a pas la qualité de production : elle confond par exemple « thoracique » et « touristique ». Les modèles recommandés n’ont pas encore été mesurés. Pour des chiffres de production, relancer :

```bash
./scripts/bench-mac-inference.sh \
  ~/Library/Application\ Support/VoxLocal/models/whisper/ggml-large-v3-turbo-q5_0.bin \
  ~/Library/Application\ Support/VoxLocal/models/llm/qwen2.5-3b-instruct-q4_k_m.gguf
```

## Runtimes natifs

`mac/VoxLocal/build-runtimes.sh` compile whisper.cpp et llama.cpp avec les options suivantes :

- `-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON` : les couches du modèle tournent sur le GPU, et la bibliothèque Metal est intégrée au binaire.
- `-DGGML_NATIVE=ON` : les noyaux CPU sont optimisés pour la puce Apple Silicon de la machine de compilation.
- `-DCMAKE_OSX_ARCHITECTURES=arm64` : binaires arm64 uniquement (`lipo -archs` affiche `arm64`).
- `-DBUILD_SHARED_LIBS=OFF` : binaires statiques, sans dylib à signer à part.

Les cibles construites sont `whisper-cli`, `llama-cli` et `llama-server`. `build.sh` copie les trois dans `VoxLocal.app/Contents/Resources/Runtimes/`.

`GGML_NATIVE` suppose que la machine de compilation n’est pas plus récente que les Mac cibles. Pour un parc mixte, compiler sur la génération de puce la plus ancienne du parc.

## Options de Whisper

`WhisperEngine.arguments` passe :

- `-fa` : flash attention ;
- `-t <activeProcessorCount>` : un fil par cœur logique, au lieu du plafond de 4 de `whisper-cli` ;
- `-bs <beamSize>` : la taille de faisceau des réglages (5 par défaut) ;
- `-np -oj -of <base>` : sortie console silencieuse, résultat écrit en JSON.

## Serveur LLM chaud

`LLMServerController` (`Sources/VoxLocal/LLMServer.swift`) :

- Démarre `llama-server --host 127.0.0.1 --port <port libre> --model <gguf> -ngl 99 -fa on -c <contexte> --no-webui --log-disable`. Le port est attribué par le noyau sur 127.0.0.1 ; le serveur n’écoute jamais sur le réseau.
- Exige une clé : elle est aléatoire à chaque démarrage et passe par la variable `LLAMA_API_KEY`, jamais par les arguments visibles dans `ps`. Un autre processus local ne peut donc pas utiliser le modèle sans cette clé.
- Attend `GET /health` = 200, en interrogeant toutes les 250 ms, 60 s au maximum.
- Garde un seul serveur, pour un modèle et un contexte donnés. Si l’un des deux change, il l’arrête puis le relance.
- Se prépare dès qu’un modèle est sélectionné (`AppState.refreshLLMServer`), pour que la première dictée ne paie pas le démarrage.
- S’arrête quand on passe en calcul GPU cloud, quand aucun modèle compatible n’est sélectionné, et quand l’app se ferme (`AppState.shutdown`).
- Écrit son PID dans `<données>/run/llama-server.pid`. Au lancement suivant, si ce PID désigne encore un `llama-server`, il est arrêté : un plantage de VoxLocal ne laisse pas un modèle en mémoire.

`LLMEngine.complete` appelle `POST /v1/chat/completions` (`stream: false`, `temperature` du mode, `max_tokens: 2048`). La dictée locale, Remote Scribe et le Prompt Corrector partagent le même serveur.

## Repli

Si le serveur ne démarre pas ou si sa requête échoue, `LLMEngine` relance la même demande avec `llama-cli`, comme avant 2.3.0. La dictée aboutit quand même. Son statut devient `completed_with_warning`, et le motif s’affiche dans l’historique, par exemple : « Serveur LLM local non démarré (…) : llama-cli a été utilisé à la place. » Le chemin `llama-cli` reste complet.

Avec la révision de llama.cpp embarquée, `llama-cli` est un client interactif : sa sortie contient un bandeau, l’invite répétée et « Exiting... ». `LLMEngine.answer(fromCLIOutput:user:)` ne garde que la réponse.

Vérifications faites le 25 septembre 2026 avec un programme de test qui compile `Engines.swift` et `LLMServer.swift` :

- Trois complétions de suite : 11,6 s pour la première (démarrage du serveur sur une machine chargée), puis 0,263 s et 0,263 s, sans avertissement.
- Serveur forcé en échec (GGUF absent) : « llama-server s’est arrêté (code 1) avant d’être prêt » remonte, puis `llama-cli` est bien tenté.
- Après l’arrêt, aucun processus `llama-server` ne reste actif.
