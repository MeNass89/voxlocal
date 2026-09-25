# VoxLocal

Application de dictée privée et entièrement locale pour macOS, désormais écrite en **Swift + SwiftUI/AppKit**. Elle reprend le floating button natif du projet SWFB dans une copie indépendante : le plugin portable original n’est ni déplacé ni modifié.

## Ce qui fonctionne

- fenêtre macOS native : Historique, Modes, Modèles et Réglages ;
- floating button AppKit identique au SWFB, toujours visible, déplaçable et mémorisé ;
- états idle, recording, processing, done et error ; clic droit pour sélectionner le mode ;
- raccourci global `⌘ ⇧ Espace` ;
- capture CoreAudio/AVFoundation vers WAV PCM mono 16 kHz, avec sélection du microphone ;
- modes JSON complets, CRUD, duplication, activation et Prompt Corrector ;
- historique local avec audio, textes brut/final, segments, modèles, statut et durée ;
- `whisper.cpp` et `llama.cpp` compilés statiquement et embarqués dans l’app ;
- pipeline micro → Whisper → prompt du mode → LLM → presse-papier/auto-collage ;
- conservation systématique du WAV si un modèle manque ou si le traitement échoue ;
- aucune API cloud et aucun téléchargement automatique.

## Calcul local ou GPU cloud

L’écran **Calcul** permet de conserver le pipeline local ou d’utiliser un GPU
cloud exposant une API compatible OpenAI. Le flux iPhone → Remote Scribe → Mac
reste identique ; seule l’exécution de Whisper et du LLM change.

Endpoints attendus :

- `POST /v1/audio/transcriptions` (multipart WAV, réponse JSON avec `text`) ;
- `POST /v1/chat/completions` (messages OpenAI, réponse `choices`) ;
- `GET /v1/models` pour le bouton de test.

L’URL, les identifiants de modèles et le token sont saisis dans VoxLocal. Dans
la version de développement signée localement, ils sont conservés dans les
réglages locaux de l’application pour éviter une nouvelle demande du Trousseau
à chaque recompilation.

## Lancer

```bash
cd /Users/nawfel/Projects/VoxLocal
./run.sh
```

Ou directement :

```bash
open "/Users/nawfel/Projects/VoxLocal/dist/VoxLocal.app"
```

L’application reste utilisable sans modèles pour parcourir l’UI, gérer les modes et enregistrer. Après l’arrêt d’une dictée, le WAV est conservé dans l’historique et une erreur explique qu’aucun modèle Whisper n’est installé.

## Construire

```bash
./setup.sh
./build.sh
```

Le bundle signé ad hoc est produit dans `dist/VoxLocal.app`. La notarisation Developer ID reste une étape de distribution commerciale.

## Modèles

Les dossiers sont créés automatiquement au premier lancement.

```text
WHISPER MODEL → placer ici :
/Users/nawfel/Library/Application Support/VoxLocal/models/whisper/

LLM MODEL → placer ici :
/Users/nawfel/Library/Application Support/VoxLocal/models/llm/
```

Whisper attend un fichier **whisper.cpp GGML `.bin`** avec un en-tête GGML valide, placé directement dans le dossier ou dans un sous-dossier. Exemple compatible : `ggml-small.bin` du dépôt Hugging Face `ggerganov/whisper.cpp`.

Le LLM attend un fichier **GGUF `.gguf` compatible llama.cpp**. Exemple : `Qwen/Qwen2.5-3B-Instruct-GGUF`, quantification `Q4_K_M` ou `Q5_K_M`.

Cliquez ensuite sur **Modèles → Rescanner**. Un modèle compatible unique est sélectionné automatiquement.

## Permissions macOS

- Microphone : nécessaire pour enregistrer.
- Accessibilité : nécessaire pour restaurer l’application cible et envoyer `⌘V`. Sans cette permission, le texte reste dans le presse-papier et l’historique.

## Tests

```bash
./test-native.sh
VOXLOCAL_TEST_MIC=1 ./test-native.sh
VOXLOCAL_TEST_PIPELINE=1 ./test-native.sh
```

Les tests couvrent modes, réglages, historique, récupération, détection GGML/GGUF, capture WAV réelle et pipeline sans modèle.

## Organisation

- `Sources/VoxLocal/` : application Swift native maintenue ;
- `Vendor/bin/` : runtimes natifs embarqués ;
- `Vendor/src/` : sources officielles épinglées de whisper.cpp et llama.cpp ;
- `Windows/` : emplacement de la future version C#/WinUI 3 ;
- `Website/` : première vitrine Web immersive de l’écosystème VoxLocal,
  RemoteScribe et de l’offre destinée aux hôpitaux.

Le plugin portable SWFB reste séparé dans `/Users/nawfel/Projects/SuperwhisperFloatingButton`.
