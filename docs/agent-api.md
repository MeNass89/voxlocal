# VoxLocal Agent API / CLI

Le dossier `agent/` fournit une passerelle locale stable pour les harness d'agents IA qui tournent sur chaque ordinateur de l'hôpital. Elle est indépendante de RunPod : les URL voix, nettoyage et LLM sont des paramètres HTTPS explicites. Aucun fournisseur, endpoint ou modèle RunPod n'est inventé dans le code. Le serveur CLI refuse les adresses d'écoute non loopback afin qu'un Bearer local ne soit jamais exposé par erreur sur le réseau.

## Démarrage local

Python 3.11+ suffit. Le serveur se lie à `127.0.0.1` par défaut, exige un Bearer token même en loopback, ne conserve aucune requête et renvoie uniquement du JSON machine-readable.

```powershell
$env:VOXLOCAL_AGENT_TOKEN = "un-secret-local-d-au-moins-32-caracteres"
python -m agent.voxlocal_agent_api serve --mock
```

Le mode `--mock` accepte uniquement des données synthétiques et produit un texte de contrôle. Pour un moteur approuvé, configurer avant le démarrage :

```powershell
$env:VOXLOCAL_AGENT_TOKEN = "..."
$env:VOXLOCAL_GPU_URL = "https://endpoint-approuve.example"
$env:VOXLOCAL_GPU_TOKEN = "..."
$env:VOXLOCAL_CLEAN_URL = "https://endpoint-nettoyage-approuve.example"
$env:VOXLOCAL_CLEAN_TOKEN = "..."
$env:VOXLOCAL_CLEAN_MODEL = "modele-nettoyage-approuve"
$env:VOXLOCAL_LLM_URL = "https://endpoint-llm-approuve.example"
$env:VOXLOCAL_LLM_TOKEN = "..."
$env:VOXLOCAL_LLM_MODEL = "modele-llm-valide-apres-benchmark"
python -m agent.voxlocal_agent_api serve --voice-model large-v3 --enable-chat
```

`VOXLOCAL_CLEAN_URL` est facultatif : s'il est absent, le nettoyage utilise l'endpoint LLM avec le modèle de nettoyage indiqué. Les secrets restent dans l'environnement du service ; ils ne doivent pas être placés dans un prompt, un fichier de configuration committé, une URL ou un argument de processus. Les options de token de compatibilité sont volontairement rejetées par le CLI. L'API distante est forcée en HTTPS, sans proxy hérité ni redirection. Le token local est obligatoire et comporte 16 à 256 caractères ; il est injecté par le coffre de secrets du service.

Le délai amont vaut 120 secondes par défaut et peut être réglé entre 1 et 300 secondes avec `VOXLOCAL_UPSTREAM_TIMEOUT`. Une valeur hors limites fait échouer le démarrage : un poste ne doit pas attendre indéfiniment un GPU indisponible. Le `requestId` généré par l'API locale est transmis au moteur via `X-Request-ID`, sans contenu clinique, pour corréler un incident. Les erreurs d'authentification ou de route amont sont marquées non relançables ; une saturation (`429`) ou une panne serveur (`5xx`) reste relançable.

## Contrat HTTP

Endpoints disponibles sur `http://127.0.0.1:47366` :

- `GET /healthz` — état prêt, version, durée et indicateur ZDR (authentifié).
- `GET /v1/capabilities` — capacités effectives (`transcribe`, `clean`, `chat`).
- `GET /v1/status` — capacités et compteur de requêtes sans contenu clinique.
- `POST /v1/transcribe` — `audio/wav` PCM mono 16 kHz 16 bits ; ou `application/octet-stream` avec `X-VoxLocal-Audio-Format: pcm_s16le_16k_mono`; ou JSON `{audioBase64, format: "wav"|"pcm_s16le_16k_mono", language?}`.
- `POST /v1/clean` — JSON `{text}`. Sans LLM, le fallback ne fait qu'un nettoyage d'espaces, pour ne jamais modifier silencieusement une négation, une dose ou un médicament.
- `POST /v1/chat` — JSON `{messages}`. Désactivé par défaut ; activer explicitement avec `--enable-chat` et configurer `VOXLOCAL_LLM_URL`/`VOXLOCAL_LLM_TOKEN`.
- `GET /v1/dictations?since=<id>&wait=<s>` — dictées postérieures à `since` (de la plus ancienne à la plus récente) ; `wait` (≤ 25 s) maintient la requête ouverte tant qu'il n'y a rien de nouveau. `since` inconnu → `404 since_not_found`.
- `GET /v1/dictations/<id>` — une dictée.
- `GET|POST /v1/patient-context` — JSON `{patientContext: "…" | null}` : patient déclaré par le clinicien, recopié dans chaque dictée créée ensuite (une ligne, 512 octets maximum).
- `POST /v1/dictations` — **mode `--mock` uniquement** : injecte une dictée synthétique `{finalTranscription, rawTranscription?, duration?, deviceName?, modeId?, processingStatus?}` pour les tests et la démo. Hors mock : `403 mock_only`.

Une dictée a exactement la forme servie par l'API loopback du Mac (`mac/VoxLocal/Sources/VoxLocal/LocalAPI.swift`, `127.0.0.1:47367`), jamais de chemin audio :

```json
{"id":"…","timestamp":"2026-09-25T13:24:50Z","deviceName":"…","modeId":"medical","rawTranscription":"…","finalTranscription":"…","processingStatus":"completed","duration":300.0,"patientContext":null}
```

**Écart Windows, dit franchement.** Le service Windows ne conserve aucune dictée (ZDR) : sans `--mock`, les routes de dictées répondent `503 capability_unavailable`. Un harness sur Windows lit donc l'API du Mac (via un tunnel TLS relu) ou cette API en `--mock` avec des données synthétiques. Une source de production côté Windows se branchera derrière le protocole `DictationSource` sans changer le contrat. Les long-polls ne consomment pas de place dans la limite de concurrence.

Toutes les réponses suivent :

```json
{"ok":true,"apiVersion":"1","requestId":"...","data":{}}
```

ou :

```json
{"ok":false,"apiVersion":"1","requestId":"...","error":{"code":"...","message":"...","retryable":false}}
```

Le `requestId` sert au support technique, jamais à retrouver un texte médical. Les erreurs ne renvoient ni corps fournisseur, ni URL complète, ni secret. Les tailles sont bornées (64 MiB audio, 2 MiB JSON, 96 KiB texte, 32 KiB par message). Les JSON refusent les clés dupliquées et les valeurs non finies. La capacité est bornée (4 appels simultanés par défaut, réglable de 1 à 16) ; une saturation renvoie `server_busy` avec `retryable: true`. Les requêtes et réponses sont traitées en mémoire et le serveur indique `persisted: false`.

## CLI pour un harness

Le CLI reprend exactement le contrat JSON :

```powershell
$env:VOXLOCAL_AGENT_TOKEN = "..."
python -m agent.voxlocal_agent_api status --pretty
python -m agent.voxlocal_agent_api doctor --pretty
python -m agent.voxlocal_agent_api transcribe .\synthetic.wav
python -m agent.voxlocal_agent_api transcribe .\synthetic.pcm  # PCM s16le mono 16 kHz
python -m agent.voxlocal_agent_api clean "Texte dicté à ponctuer"
python -m agent.voxlocal_agent_api chat "Question de test" # seulement si activé
```

Pour un texte clinique, ne le passez pas comme argument (la liste des
processus peut être visible localement) : utilisez stdin.

```powershell
Get-Content .\texte-synthetique.txt -Raw | python -m agent.voxlocal_agent_api clean --stdin --pretty
Get-Content .\question-synthetique.txt -Raw | python -m agent.voxlocal_agent_api chat --stdin --pretty
```

Après `pip install -e .`, l'équivalent court est `voxlocal-agent status --pretty`. Pour intégrer un harness, utiliser la sortie JSON et `error.code` plutôt que parser les logs humains.

Le CLI accepte uniquement `.wav`/`.wave` (WAV PCM mono 16 kHz 16 bits) ou
`.pcm`/`.raw` (PCM s16le mono 16 kHz). Il refuse les extensions ambiguës et les
fichiers de plus de 64 MiB avant lecture, puis ajoute automatiquement l'en-tête
de format pour le flux PCM brut.

Sur Windows, [`agent/run-windows.ps1`](../agent/run-windows.ps1) lance le même service en loopback. Il exige `VOXLOCAL_AGENT_TOKEN` déjà fourni par le compte de service et ne place aucun secret dans les arguments du processus :

```powershell
$env:VOXLOCAL_AGENT_TOKEN = "..."
powershell -ExecutionPolicy Bypass -File .\agent\run-windows.ps1
```

Les scripts d'agents doivent vérifier `ok` et `error.code`, conserver le `requestId`, et traiter `retryable=true` avec une file bornée et backoff. Ils ne doivent pas réessayer automatiquement une transcription après un résultat `completed`.

## Tests

`python3 -m unittest agent.test_agent_api -v` exécute les 15 tests de l'API et
du CLI (25 septembre 2026) : Bearer, contrats JSON, JSON strict, limites,
erreurs amont, timeouts, refus de l'HTTP distant, profil mock hermétique, et
les routes de dictées (filtre `since`, forme sans audio, long-poll qui rend la
main dès qu'une dictée arrive, contexte patient, injection réservée au mock).

## Limites et chemin de production

Cette passerelle ne signe pas de conformité RGPD. Avant des données patient, l'hôpital doit valider le DPA/ZDR, la région, les journaux et la rétention du fournisseur, puis remplacer le simple token local par un enrôlement d'appareil (mTLS ou équivalent). Pour un poste partagé, installer le serveur comme service Windows avec un compte dédié et une ACL sur ses secrets. Le mode `--mock` est le seul mode de développement sans certificat TLS côté GPU.
