# Banc d’appel d’outils

[`tool_calling_bench.py`](tool_calling_bench.py) (Python 3.11+, bibliothèque standard seule) envoie des consignes cliniques françaises à un point `POST {base}/chat/completions` OpenAI-compatible, avec les trois schémas d’outils du scribe :

| Outil (nom logique) | Nom sur le fil | Rôle |
|---|---|---|
| `dictation.get` | `dictation_get` | Lire une dictée nettoyée |
| `patient.read` | `patient_read` | Lire le dossier (lecture seule) |
| `record.draft_edit` | `record_draft_edit` | Brouillon SOAP section par section, avec citations de la dictée |

Les noms de fonction OpenAI n’acceptent pas le point : les noms logiques voyagent avec un tiret bas.

Cinq consignes par passe, dont un brouillon SOAP à partir de la dictée synthétique « entorse » (copiée de `portail-med-api/samples/transcript_entorse.txt`).

## Mesures

| Champ | Sens |
|---|---|
| `tool_call_validity_rate` | Part des requêtes dont le premier appel d’outil nomme un outil déclaré, avec des arguments JSON qui respectent les champs requis et les types du schéma |
| `expected_tool_rate` | Part des requêtes qui appellent l’outil attendu (valide ou non) |
| `soap_draft_complete_rate` | Parmi les appels `record.draft_edit`, part avec les quatre sections, chacune avec un texte proposé et au moins une citation |
| `latency_s.p50/p95` | Latence de bout en bout par requête (rang le plus proche) |
| `completion_tokens_per_s.p50/p95` | Jetons générés divisés par la latence de bout en bout (inclut le prefill) |

Chaque échantillon garde l’outil appelé, les erreurs de validation, `finish_reason` et les jetons consommés. Le code de sortie vaut 1 si une requête a échoué au niveau HTTP.

## Contre le Pod (Qwen3.8-27B)

```bash
export VOXLOCAL_LLM_URL='https://<pod>:8443/llm/v1'
export VOXLOCAL_LLM_TOKEN='…'        # lu dans l’environnement, jamais en argument
python3 harness/bench/tool_calling_bench.py --model qwen3.8-27b --repeats 10 \
  --note "RunPod <GPU>, llama-server <build>, Qwen3.8-27B Q4_K_M" \
  --out docs/superpowers/evidence/<date>-harness-bench-qwen3.8.json
```

`--model` doit être l’identifiant que le serveur attend ; `llama-server` sert son unique modèle quel que soit ce champ. Options : `--max-tokens` (2048), `--temperature` (0), `--timeout` (180 s), `--token-env` pour lire le jeton dans une autre variable.

## Preuve locale du 2026-09-25

[`docs/superpowers/evidence/2026-09-25-harness-bench.json`](../../docs/superpowers/evidence/2026-09-25-harness-bench.json) a été produit contre un `llama-server` local (Qwen2.5-0.5B-Instruct Q4_K_M, `-c 32768 -n 512 --jinja`). Il prouve le banc et les schémas, pas le modèle de production : le 0,5B choisit le bon outil pour les quatre lectures mais ne termine pas le brouillon SOAP avant la limite de jetons.
