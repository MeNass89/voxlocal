# Harness clinique VoxLocal

Le médecin dicte en se déplaçant ; VoxLocal transcrit et nettoie en temps réel ; un agent sur le poste reçoit la dictée, prépare les modifications du dossier patient et **attend un feu vert explicite** avant d’écrire quoi que ce soit dans le portail.

Le harness est [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`, MIT), épinglé à **`@deepseek-ai/dsh` 0.1.7-rc.2** (commit `477b4f4`). `dsh` est une préversion développeur qui casse souvent : la version exacte est figée dans [`profile/package.json`](profile/package.json) et dans `profile/pnpm-lock.yaml`. Ne la changer qu’avec une revue du profil.

Plan de la vague 3 : [`docs/superpowers/plans/2026-09-25-voxlocal-wave3-harness.md`](../docs/superpowers/plans/2026-09-25-voxlocal-wave3-harness.md).

## État

| Brique | Dossier | État |
|---|---|---|
| Profil `scribe` + fournisseur GPU | [`profile/`](profile/README.md) | H1 fait |
| Banc d’appel d’outils | [`bench/`](bench/README.md) | H1 fait |
| Flux de dictée (`voxlocal-tools`, feeder) | [`plugins/voxlocal-tools/`](plugins/voxlocal-tools), [`ingest/`](ingest) | H2 fait |
| Pont portail + mock enregistré (`portail-tools`) | [`bridge/`](bridge), [`plugins/portail-tools/`](plugins/portail-tools) | H3 fait |
| Feu vert, audit, persona, boucle | [`plugins/scribe-approval/`](plugins/scribe-approval), [`plugins/scribe-persona/`](plugins/scribe-persona), [`tests/test_loop.py`](tests/test_loop.py) | H4 fait |
| Démo de bout en bout | [`demo/`](demo/README.md) | H5 fait |
| Lanceurs Windows, CI | [`run-web.ps1`](run-web.ps1), [`ingest/run-feeder.ps1`](ingest/run-feeder.ps1), job `harness` de [`ci.yml`](../.github/workflows/ci.yml) | H6 fait |

## Architecture

```
 iPhone / Mac VoxLocal ──dictée nettoyée──▶ API dictées (loopback, H2)
                                               │  dictation_feeder.py : une dictée terminée = un message
                                               ▼
 ┌──────────────────────────── dsh, profil « scribe » (poste du médecin) ───────────────────────────┐
 │  modèle Qwen3.8-27B (fournisseur voxlocal-gpu, VOXLOCAL_LLM_URL)                                  │
 │  scribe-persona   sections du prompt : rôle, boucle, règles, SOAP, feu vert, outils absents       │
 │  voxlocal-tools   dictation_list / dictation_get / dictation_retranscribe                         │
 │  portail-tools    patient_* , record_find_sections, record_read_section, record_draft_edit,       │
 │                   record_apply, record_restore          ── jeton outils (PORTAIL_BRIDGE_TOKEN) ──┐ │
 │  scribe-approval  tools/pre-execute : record_apply / record_restore ⇒ « ask »                    │ │
 │                   ctx.approval (politique ask | never) ⇒ panneau « Waiting for approval » du chat│ │
 │                   feu vert humain ⇒ approve_draft ── jeton approbateur (…_APPROVER_TOKEN) ──┐   │ │
 │                   guard() : pas de feu vert relayé pour cet appel ⇒ refus                    │   │ │
 │                   audit ⇒ harness/audit/approvals.jsonl                                      │   │ │
 └──────────────────────────────────────────────────────────────────────────────────────────────┼───┼─┘
                                                                                                ▼   ▼
                         pont portail (JSON-RPC, 127.0.0.1:47368, H3) = frontière de sécurité
                         brouillons immuables (bridge/drafts.jsonl), feu vert à usage unique,
                         10 min, lié au patient / rencontre / section / empreintes ; écriture
                         atomique ; audit harness/audit/portal-writes.jsonl
                                               ▼
                         portail patient (aujourd’hui : mock enregistré ; demain : portail réel)
```

Le tour type : la dictée arrive ; l’agent lit le dossier, prépare un **brouillon par section** (`record_draft_edit`, avec citations exactes de la dictée, stocké par le pont), le résume, puis appelle `record_apply`. dsh suspend l’appel et affiche au médecin le patient, la rencontre, la section, le diff exact et les citations ([capture](../docs/superpowers/evidence/2026-09-25-harness-approval-card.png)). « Allow once » : le plugin (jamais le modèle) transmet la décision au pont, puis l’outil écrit. « Reject », absence de réponse ou politique `never` : l’outil ne s’exécute pas et le modèle lit « Application refusée : aucun feu vert. ».

Temps réel : aujourd’hui une dictée **terminée** est livrée en un message ; les segments stabilisés pendant la dictée arrivent avec H2b.

## Lancer l’interface web (macOS, développement)

Prérequis : Node ≥ 22.19, pnpm.

```bash
export VOXLOCAL_LLM_URL='https://<pod>:8443/llm/v1'   # passerelle OpenAI-compatible, se termine par /v1
export VOXLOCAL_LLM_TOKEN='…'                        # jeton de la passerelle GPU, jamais dans git
export PORTAIL_BRIDGE_TOKEN="$(openssl rand -hex 24)"          # jeton outils du pont
export PORTAIL_BRIDGE_APPROVER_TOKEN="$(openssl rand -hex 24)" # jeton approbateur, différent
export SCRIBE_CLINICIAN='dr.dupont'                  # nom inscrit dans les journaux d’audit
export VOXLOCAL_API_URL='http://127.0.0.1:47367'     # API locale de VoxLocal (app Mac)
export VOXLOCAL_API_TOKEN='…'                        # Réglages › iPhone › Harness local › Copier
python3 -m harness.bridge.portail_bridge --backend mock &   # pont portail, mock enregistré ; lit les dictées sur l’API
harness/run-web.sh                                   # dsh --profile scribe --no-open
```

Le pont vérifie chaque citation contre la dictée lue sur l’API VoxLocal (`GET /v1/dictations/<id>`) ; le contexte patient de la dictée doit déclarer le patient et la rencontre (`patient=<id> rencontre=<id>`). `PORTAIL_DICTATION_DIR` (dossier de `dictation-*.json`) s’y ajoute ou la remplace ; en mock, les fixtures synthétiques restent consultées en dernier. En mode réel sans aucune source, le pont refuse tout brouillon.

Optionnel : `PORTAIL_BRIDGE_URL` (défaut `http://127.0.0.1:47368/`), `SCRIBE_APPROVALS_AUDIT` (défaut `harness/audit/approvals.jsonl`). `run-web.sh` refuse, comme `run-web.ps1`, une `VOXLOCAL_LLM_URL` en HTTP vers un hôte distant ou portant des identifiants.

Le script installe `dsh` au verrou près (`pnpm install --frozen-lockfile`), place le Harness home dans `harness/.dsh-home/` (ignoré par git), y relie le profil `scribe`, puis imprime une ligne `dsh web: http://127.0.0.1:3080/?token=…`. Ouvrir cette URL dans le navigateur du poste. Les options suivantes vont à l’app web (`--port 3081`, par exemple).

## Lancer sous Windows (PowerShell)

Même contrat de variables d’environnement, depuis la racine du dépôt :

```powershell
$env:VOXLOCAL_LLM_URL = 'https://<pod>:8443/llm/v1'
$env:VOXLOCAL_LLM_TOKEN = '…'                 # depuis le coffre de secrets, jamais en argument
$env:PORTAIL_BRIDGE_TOKEN = '…'; $env:PORTAIL_BRIDGE_APPROVER_TOKEN = '…'   # deux valeurs différentes
.\harness\run-web.ps1                         # dsh --profile scribe --no-open ; --port 3081 passe à l’app web
$env:VOXLOCAL_API_TOKEN = '…'
.\harness\ingest\run-feeder.ps1 --backend dryrun   # options du feeder transmises telles quelles
```

`run-web.ps1` refuse un `--host` hors boucle locale et tout `--trusted-host`, refuse une URL HTTP distante pour le modèle et un `PORTAIL_BRIDGE_URL` hors boucle locale, et relie le profil par une jonction (pas de droit administrateur). `run-feeder.ps1` refuse une API de dictées hors boucle locale. Les deux scripts sont exécutés sous `pwsh` 7.6 sur macOS (refus et lancement réel) ; la CI Windows les analyse avec PowerShell 7 et Windows PowerShell 5.1, et le job `harness` les lance sous `pwsh` sur ubuntu et macOS. Ils n’ont pas encore tourné sur un poste Windows.

## Démo de bout en bout

`bash harness/demo/run-demo.sh --check` puis `bash harness/demo/run-demo.sh` : API de dictées en mock, feeder, pont sur le portail enregistré, modèle scripté (ou `--provider local|pod`), chat `dsh`. Mode d’emploi : [`demo/README.md`](demo/README.md) ; script de 90 secondes : [`docs/demo-runbook.md`](../docs/demo-runbook.md#parcours-agent).

## Posture de sécurité

- **Aucune donnée patient** dans ce dossier : fixtures et dictées de test synthétiques.
- **Secrets hors git** : le jeton GPU vient de `VOXLOCAL_LLM_TOKEN` (`apiKeyEnv` de `dsh`), l’URL de `VOXLOCAL_LLM_URL`. Les identifiants du portail ne seront lus que par le pont (H3), jamais par le processus `dsh`.
- **Écoute locale seulement** : l’interface web `dsh` n’écoute que sur la boucle locale et refuse `--host 0.0.0.0` ; l’URL de démarrage porte un jeton de processus.
- **Le pont décide, pas le harness** (amendement 1) : le pont refuse `apply` et `restore` (403) tant qu’un humain n’a pas approuvé ce brouillon précis, et 409 si la section ou le brouillon a changé. Après l’écriture, une relecture différente du texte approuvé déclenche la restauration de la sauvegarde et un échec (pont et adaptateur réel). Un brouillon exige une source de dictées : chaque citation doit se trouver dans une dictée déclarant le même patient et la même rencontre, sinon refus ; il n’y a pas de mode permissif. La porte `dsh` (`scribe-approval`) est l’interface qui pose la question et relaie la réponse ; elle n’est pas la frontière. Test : `test_without_the_harness_gate_the_bridge_still_refuses` retire le plugin et constate que le pont refuse quand même.
- **Deux jetons** : les outils ne portent que `PORTAIL_BRIDGE_TOKEN` (lire, préparer, demander l’écriture d’un brouillon approuvé). `PORTAIL_BRIDGE_APPROVER_TOKEN` n’est utilisé que par `scribe-approval`, après un « Allow once ». Aucun outil exposé au modèle n’appelle `approve_draft`, et le preset `scribe` n’a ni terminal ni accès fichiers : le modèle ne peut pas lire l’environnement du processus. Les deux jetons vivent dans le même processus `dsh` ; les séparer davantage (approbateur hors processus) est une amélioration possible, pas un prérequis tant que le modèle n’a aucun outil générique.
- **Feu vert lié à la session** : `scribe-approval` indexe la question et l’accord par session et identifiant d’appel ; l’accord donné dans une session n’autorise jamais un appel d’une autre session.
- **Politique** : `ask` dans le profil `scribe`. Sans répondeur (run sans interface), la demande échoue fermée (`unavailable`). `never` refuse toute écriture sans consulter personne.
- **Audit** : `harness/audit/approvals.jsonl` (chaque décision : autorisé, refusé, annulé, indisponible, relais échoué, puis le résultat de l’écriture) et `harness/audit/portal-writes.jsonl` (côté pont). Identifiants et empreintes seulement, jamais le texte clinique : un identifiant fourni par le modèle n’est inscrit que s’il a la forme `drf-…`/`bak-…` (sinon son empreinte), et les erreurs par code et statut, jamais par message. Les deux dossiers sont ignorés par git.
- **Feeder au moins une fois** : `dictation_feeder.py` enregistre les dictées en cours d’envoi avant d’envoyer ; après un arrêt, il les renvoie marquées « Renvoi possible après interruption (même identifiant de dictée ; ignorer si déjà reçu) ». Le backend `sdk` démarre le profil `scribe` (créé par `run-web.sh`) et refuse de démarrer sans lui.

## Tests

```bash
python3 -m unittest discover -s harness/tests -t . -v   # pont, feeder, lanceurs, boucle
(cd harness/plugins/portail-tools && pnpm install && pnpm test)
(cd harness/plugins/scribe-approval && pnpm install && pnpm test)
(cd harness/plugins/scribe-persona && pnpm install && pnpm test)
```

`test_loop.py` fait tourner le vrai `dsh` (profil sans interface), le vrai pont et les quatre plugins, avec un **modèle scripté** (serveur OpenAI-compatible qui renvoie `record_find_sections` → deux `record_draft_edit` → `record_apply`). Il vérifie : brouillons créés au pont avant toute écriture ; politique `never` ⇒ aucune écriture ; sans répondeur ⇒ aucune écriture ; feu vert ⇒ exactement une écriture par brouillon, lignes d’audit des deux côtés ; porte retirée ⇒ le pont refuse ; rejeu après redémarrage du pont ⇒ aucune écriture. Le vrai modèle se mesure à part avec [`bench/`](bench/README.md).

