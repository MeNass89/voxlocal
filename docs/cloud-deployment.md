# Déploiement cloud — GPU privé RunPod

Ce document décrit le chemin « GPU privé » de VoxLocal : une image Docker qui
fait tourner Whisper (`whisper-server`) et un LLM Qwen (`llama-server`) sur un
Pod RunPod, derrière une seule porte HTTPS authentifiée. Le poste (Mac, Windows
ou agent local) envoie la dictée à ce Pod au lieu de l’inférer lui-même.

État au 25 septembre 2026 : l’image, le script de déploiement et le banc de
mesure sont dans le dépôt et ont été exercés localement (voir « Preuve
locale »). **Aucun Pod n’a encore été provisionné** : l’image n’a pas été
construite (pas de Docker sur la machine de développement) et les chiffres GPU
viendront du premier déploiement sur un compte RunPod. Ce chemin n’est pas
« prêt clinique » tant que la liste ZDR/DPA ci-dessous n’est pas fermée.

## Ce qui tourne dans le Pod

| Composant | Écoute | Rôle |
| --- | --- | --- |
| Caddy 2.11.4 | `:8443/tcp`, **seul port exposé** | TLS 1.3, exige `Authorization: Bearer <token>`, route vers les services |
| `whisper-server` (whisper.cpp `v1.9.3`, CUDA) | `127.0.0.1:8001` | `POST /v1/audio/transcriptions` |
| `llama-server` (llama.cpp `a298422`, CUDA) | `127.0.0.1:8003` | `GET /v1/models`, `POST /v1/chat/completions` ; vérifie aussi le token |
| `start-all.sh` | — | supervise les trois processus ; si l’un s’arrête, il arrête les autres et sort, ce qui arrête le conteneur (vérifier la politique de redémarrage du Pod) |

Les deux moteurs sont construits aux **mêmes commits** que les sous-modules de
l’app Mac (`mac/VoxLocal/Vendor/src`) ; un test (`tests/test_runpod_runtime.py`)
échoue si le `Dockerfile` et les sous-modules divergent.

Routes publiées par la porte (toutes exigent le token) :

| Route | Destination |
| --- | --- |
| `GET /voice/v1/models` | réponse de la porte (Whisper n’a pas cette route) |
| `POST /voice/v1/audio/transcriptions` | Whisper |
| `GET /llm/v1/models`, `POST /llm/v1/chat/completions` | LLM |
| `GET /v1/models`, `POST /v1/audio/transcriptions`, `POST /v1/chat/completions` | idem, sans préfixe, pour un poste configuré avec une seule URL (app Mac) |
| toute autre route | `404` ; sans token valide : `401` |

L’interface web de `llama-server` n’est pas construite et son endpoint `/slots`
est désactivé ; le formulaire web et la route `/load` de `whisper-server` existent
dans le binaire mais ne sont pas routés par la porte. La porte n’a pas de
journal d’accès. Whisper journalise la durée, la langue et le **nom de fichier**
envoyé par le client (les postes VoxLocal envoient `audio.wav`), jamais le
texte ; `llama-server` ne journalise pas le contenu à son niveau par défaut.

## Pré-requis

- un compte RunPod et une clé API (`RUNPOD_API_KEY`) ;
- `runpodctl` (2.14 ou plus récent) :
  `curl -sSL https://cli.runpod.net | bash` ou
  `brew install runpod/runpodctl/runpodctl` ;
- Docker avec `buildx` pour construire l’image `linux/amd64` (sur Mac Apple
  Silicon, la compilation CUDA sous émulation est très longue : préférer un
  runner Linux x86_64 ou une CI) ;
- un registre d’images (Docker Hub, GHCR…) ; pour une image privée, un
  identifiant créé avec `runpodctl registry create` ;
- `python3` et `openssl` sur la machine qui déploie.

## Déployer en une commande

Depuis la racine du dépôt :

```bash
export RUNPOD_API_KEY=<clé RunPod>
export VOXLOCAL_IMAGE=docker.io/<compte>/voxlocal-runpod:2026-09-25
export VOXLOCAL_TOKEN_SECRET=<nom du secret RunPod contenant le token>
bash cloud/runpod/deploy.sh
```

Le script :

1. vérifie ses pré-requis (sans `runpodctl`, `RUNPOD_API_KEY` ou
   `VOXLOCAL_TOKEN_SECRET` il sort avec le code `2` et la marche à suivre) ;
2. construit et pousse l’image, puis l’épingle par son digest `sha256` ;
3. crée un template RunPod (volume persistant sur `/workspace`, port `8443/tcp`) ;
4. crée le Pod sur `VOXLOCAL_GPU` (défaut `NVIDIA GeForce RTX 4090`, Secure
   Cloud) ;
5. attend l’adresse publique, lit l’empreinte SHA-256 du certificat dans le
   journal du Pod, récupère le certificat réellement servi, vérifie qu’ils
   correspondent et l’enregistre dans `~/.voxlocal/runpod/<pod>-edge.pem` ;
6. affiche la configuration du poste.

Le premier démarrage télécharge les modèles dans le volume (≈ 3,7 Go avec les
valeurs par défaut) ; les suivants les réutilisent.

Variables utiles :

| Variable | Défaut | Effet |
| --- | --- | --- |
| `VOXLOCAL_GPU` | `NVIDIA GeForce RTX 4090` | identifiant GPU RunPod (`runpodctl gpu list`) |
| `VOXLOCAL_CLOUD_TYPE` | `SECURE` | `COMMUNITY` est moins cher mais héberge chez des tiers : à exclure pour des données patient |
| `VOXLOCAL_DATA_CENTER` | — | centre de données, p. ex. un centre européen pour le RGPD (`runpodctl datacenter list`) |
| `VOXLOCAL_VOLUME_GB` / `VOXLOCAL_NETWORK_VOLUME_ID` | `30` / — | volume du Pod ou volume réseau existant |
| `VOXLOCAL_TOKEN_SECRET` | **obligatoire** | nom du secret RunPod contenant le token |
| `VOXLOCAL_SKIP_BUILD=1` | — | réutiliser une image déjà poussée |
| `WHISPER_MODEL_URL`, `WHISPER_MODEL`, `WHISPER_MODEL_SHA256` | `ggml-large-v3-turbo.bin`, révision Hugging Face épinglée | modèle vocal |
| `LLM_MODEL_URL`, `LLM_MODEL`, `LLM_MODEL_SHA256` | `qwen2.5-3b-instruct-q4_k_m.gguf`, révision épinglée | LLM de correction |
| `WHISPER_LANGUAGE` | `fr` | langue forcée (`auto` pour détecter) |
| `VOXLOCAL_LLM` | `on` | `off` pour un Pod voix seule |

Les modèles par défaut sont vérifiés par SHA-256 ; un autre modèle doit venir
avec son empreinte (ou une valeur vide, explicitement non vérifiée). Ce sont des
points de départ pour la mesure, pas un choix clinique.

## Le token

- Générer le token sur le poste d’administration (`openssl rand -hex 32`), le
  ranger dans le coffre du poste, créer un secret RunPod avec la même valeur
  (console RunPod → Secrets ; 32 à 256 caractères `A–Z a–z 0–9 . _ ~ -`) et
  lancer le déploiement avec `VOXLOCAL_TOKEN_SECRET=<nom>`. Le template
  référence `{{ RUNPOD_SECRET_<nom> }}` ; la valeur ne transite jamais par le
  script. Le Pod l’écrit dans `/workspace/voxlocal/api-token` (mode `600`).
  Rotation : modifier le secret puis redémarrer le Pod.
- `deploy.sh` exige ce secret : l’image ne lance pas de serveur SSH, un token
  généré dans le Pod (comportement d’`entrypoint.sh` sans secret, utile hors
  RunPod) ne pourrait pas être relu depuis le poste.
- `deploy.sh` ne lit ni n’écrit jamais le token.

## Le certificat

Sans certificat fourni, le Pod crée au premier démarrage une clé EC P-256 et un
certificat auto-signé (825 jours, SAN `localhost`, `127.0.0.1` et l’IP publique
du Pod) dans `/workspace/voxlocal/tls/`. L’empreinte SHA-256 est écrite dans le
journal à chaque démarrage ; `deploy.sh` la compare au certificat servi. Si l’IP
publique change, le certificat est réémis avec la même clé : l’empreinte change,
il faut ré-épingler (relancer `deploy.sh` avec `VOXLOCAL_SKIP_BUILD=1`, ou
récupérer le nouveau certificat et vérifier son empreinte dans le journal).

Pour un nom DNS et une CA de l’hôpital : déposer le certificat et la clé dans le
volume et définir `VOXLOCAL_TLS_CERT` / `VOXLOCAL_TLS_KEY` (clé en mode `600`,
refusée sinon).

## Configurer le poste

Les valeurs exactes sont affichées à la fin de `deploy.sh`.

**Serveur Remote Scribe Python (Windows, Linux) :**

```bash
export VOXLOCAL_GPU_URL=https://<ip>:<port>/voice
export VOXLOCAL_LLM_URL=https://<ip>:<port>/llm
export VOXLOCAL_GPU_TOKEN=<token>        # depuis le coffre, jamais dans un fichier du dépôt
python3 server/voxlocal_server.py ... --gpu-ca-file ~/.voxlocal/runpod/<pod>-edge.pem
```

Sous Windows : `-GpuCAFile` de `server\run-windows.ps1`. Les deux URL partagent
le même hôte, le serveur réutilise donc `VOXLOCAL_GPU_TOKEN` pour le LLM ;
`VOXLOCAL_LLM_TOKEN` n’est nécessaire que pour un LLM sur un autre hôte.

**App Mac :** Réglages → GPU cloud, adresse `https://<ip>:<port>` (sans
préfixe), token dans le champ prévu (stocké dans le Trousseau). L’app utilise
le magasin de confiance macOS : avec le certificat auto-signé, l’ajouter au
Trousseau Système comme approuvé pour SSL (Trousseau d’accès, ou
`sudo security add-trusted-cert -d -r trustAsRoot -p ssl -k /Library/Keychains/System.keychain <pod>-edge.pem`),
ou fournir un certificat d’une CA déjà approuvée par le poste.

**API agent locale :** mêmes variables `VOXLOCAL_GPU_URL` / `VOXLOCAL_LLM_URL`.
Elle n’a pas encore d’option `--gpu-ca-file` : utiliser un certificat approuvé
par le système.

Vérifier la liaison :

```bash
VOXLOCAL_API_TOKEN=<token> python3 cloud/runpod/benchmark.py --iterations 5 --timeout 30 \
  --ca-file ~/.voxlocal/runpod/<pod>-edge.pem \
  --voice-url https://<ip>:<port>/voice --llm-url https://<ip>:<port>/llm > bench.json
python3 cloud/runpod/bench-report.py bench.json
```

## Mesurer

`benchmark.py` n’envoie que des données synthétiques : un WAV silencieux de
250 ms, une tonalité déterministe de 10 s et une phrase clinique française
fictive. Il mesure p50/p95 par opération et les tokens/s du LLM
(`usage.completion_tokens` ÷ latence de la requête), et n’enregistre aucun texte
de réponse. `bench-report.py` convertit le JSON en tableau Markdown.

### Preuve locale (25 septembre 2026)

Mêmes binaires que l’image (compilés depuis les sous-modules, Metal au lieu de
CUDA), modèles minuscules (`ggml-tiny.bin`, Qwen2.5-0.5B Q4_0), démarrés par
`entrypoint.sh` et `start-all.sh`, mesurés à travers la porte Caddy en TLS 1.3
avec token, sur un MacBook Air M2 16 Go. Fichier :
`docs/superpowers/evidence/2026-09-25-cloud-bench-local.json`.

| Service | Opération | OK | p50 ms | p95 ms | moyenne ms | tokens/s p50 | tokens/s p95 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| voice | models | 1/1 | 6.42 | 6.42 | 6.42 | – | – |
| voice | audio_transcriptions_250ms | 3/3 | 1356.2 | 1363.7 | 1345.6 | – | – |
| voice | audio_transcriptions_10s | 3/3 | 72.8 | 74.5 | 73.0 | – | – |
| llm | models | 1/1 | 1.84 | 1.84 | 1.84 | – | – |
| llm | chat_completions | 3/3 | 602.8 | 664.7 | 610.7 | 104.5 | 111.6 |

Ces chiffres prouvent le chemin (image → porte TLS → moteurs → banc de mesure),
**pas la performance GPU**. Whisper complète toute entrée à 30 s : le clip
silencieux de 250 ms déclenche des relances de décodage et coûte plus cher que
la tonalité de 10 s. Aucune qualité de transcription n’est mesurée ici.

## Coûts

Un Pod est facturé à la seconde tant qu’il tourne (`runpodctl pod stop <id>`
arrête le GPU ; le volume reste facturé). Prix RunPod relevés le 25 septembre
2026 (API publique, $/h, susceptibles de changer) :

| GPU | VRAM | Secure Cloud | Community Cloud |
| --- | ---: | ---: | ---: |
| NVIDIA GeForce RTX 4090 (défaut) | 24 Go | 0,74 | 0,34 |
| NVIDIA L4 | 24 Go | 0,49 | 0,44 |
| NVIDIA RTX A5000 | 24 Go | 0,27 | 0,16 |
| NVIDIA A40 | 48 Go | 0,49 | 0,35 |

Grille à remplir pour un service :

| Poste | Valeur |
| --- | --- |
| GPU retenu, $/h (Secure) | … |
| Heures d’ouverture par jour × jours par mois | … × … |
| Coût GPU mensuel = $/h × heures | … |
| Volume (Go × tarif stockage) | … |
| Dictées par jour (mesure du service) | … |
| Coût par dictée = coût mensuel ÷ dictées du mois | … |
| Latence p95 mesurée sur ce GPU (`benchmark.py --iterations 20`) | … |

Exemple de calcul : RTX 4090 Secure, 10 h/j, 22 j/mois → 0,74 × 220 = 162,80 $
de GPU par mois, hors volume.

## Avant des données patient

Liste reprise de `docs/release-readiness.md` ; elle reste externe au dépôt :

1. **Identité réseau** : fournir certificats gérés, pinning ou mTLS, enrôlement,
   rotation et révocation d’appareil. Le code d’appairage seul ne suffit pas.
2. **Fournisseur GPU** : enregistrer région, image et digest, versions CUDA et
   modèles, logs, snapshots, rétention, suppression et DPA/ZDR. Un header
   `X-Remote-Scribe-ZDR` ne constitue pas une preuve contractuelle.
3. **Modèles** : benchmark synthétique séparé voix, nettoyage et LLM ; mesurer
   latence, VRAM, coût, saturation, erreurs et stabilité avant de choisir une
   taille Qwen ou un modèle Whisper.
4. **Déploiement poste** : valider le paquet Windows sur un poste réel, puis
   remplacer la tâche planifiée de démonstration par un service signé avec coffre
   Credential Manager ou DPAPI ; signer et notariser le DMG macOS, puis signer
   l’app iOS avec le profil de distribution approprié.
5. **Validation clinique** : revue DPO/sécurité, politique de rétention,
   procédure d’incident, test de suppression, journalisation sans PHI et
   validation humaine des sorties de nettoyage avant usage réel.

Propres à ce chemin : Secure Cloud et centre de données documentés, DPA signé
avec RunPod, arrêt ou suppression du Pod et du volume en fin d’usage, rotation
du token, et une preuve que le volume ne conserve ni audio ni texte (à
vérifier sur le Pod : Whisper reçoit l’audio en mémoire, sans `--convert` il
n’écrit pas de fichier temporaire ; les journaux sont dans
`/workspace/voxlocal/logs`).
