# Remote Scribe WebClient

Page privée pour utiliser le microphone d’un iPhone sans installer d’application. Elle sert l’interface en HTTPS sur le Wi-Fi local et traduit les chunks PCM 16 kHz vers le protocole Remote Scribe déjà utilisé par VoxLocal et Superwhisper.

## Premier lancement

```bash
cd RemoteScribe/WebClient
./run-webclient.sh --backend superwhisper
```

Au premier lancement seulement, le script ouvre sur le Mac un QR code stable à scanner avec l’iPhone. Il mène à une petite page d’installation locale : installer le certificat proposé, puis activer sa confiance dans **Réglages → Général → Informations → Réglages des certificats**.

## Utilisation

Depuis la page d’installation, toucher **Ouvrir Remote Scribe**, renseigner une seule fois le nom de la personne et le nom du PC, puis autoriser le microphone. Le profil et l’accès sécurisé sont mémorisés dans Safari : après un redémarrage du Mac, la page déjà ouverte se reconnecte automatiquement sans nouveau QR ni code.

Chaque profil possède un identifiant et un secret aléatoires conservés dans Safari. Ses dictées sont indexées sur le Mac et réapparaissent après une actualisation de la page. Le texte IA, la transcription brute et la réécoute du WAV sont accessibles uniquement lorsque ce profil occupe le PC.

Une seule personne peut occuper le PC à la fois. Le bouton **Libérer ce PC**, la fermeture de la page ou 20 secondes sans nouvelles libèrent la place ; l’arrêt du Mac remet immédiatement le verrou à zéro. Pour réafficher volontairement le QR stable, utiliser `./run-webclient.sh --show-qr --backend superwhisper`.

Pour VoxLocal, lancer VoxLocal avant la page ou utiliser `./run-webclient.sh --backend voxlocal` quand VoxLocal n’est pas déjà ouvert.

La page et l’audio restent sur le réseau local. Elle envoie `PAIR`, `START_SESSION`, les `AUDIO_CHUNK`, puis `STOP_SESSION` au même cœur Remote Scribe.

## Stockage local

- Base de l’historique : `~/Library/Application Support/RemoteScribe/history/history.sqlite3`
- WAV PCM 16 kHz mono : `~/Library/Application Support/RemoteScribe/sessions/<UUID>/remote.wav`
- Certificat et clé d’accès Web : `~/Library/Application Support/RemoteScribe/web/`

L’historique ne fait aucune copie audio supplémentaire : il référence le WAV déjà créé pour la transcription. Safari lit directement ce WAV avec des requêtes par plages d’octets, sans conversion préalable.
