# harness/ — agent clinique local (DeepSeek Harness)

Couche agent de VoxLocal : le médecin dicte, l'agent reçoit les dictées, prépare les modifications du dossier et attend un feu vert explicite. Plan : `docs/superpowers/plans/2026-09-25-voxlocal-wave3-harness.md`. dsh épinglé : `@deepseek-ai/dsh` **0.1.7-rc.2** (commit `477b4f4`).

## Flux des dictées (H2)

```
VoxLocal Mac ── 127.0.0.1:47367 (Bearer, Réglages › iPhone › Harness local)
   │   ou API agent Python `--mock` (127.0.0.1:47366, Windows / démo)
   ├── plugins/voxlocal-tools   dictation_list · dictation_get · dictation_retranscribe (lecture seule)
   └── ingest/dictation_feeder.py → session dsh
```

- **Mac** : activer « Exposer les dictées au harness local », copier le token. Le token vit dans le trousseau (`com.voxlocal.local-api` / `token`), jamais dans un fichier. `POST /v1/patient-context` déclare le patient en cours ; chaque dictée créée ensuite le porte (`patientContext`).
- **Plugin** : `VOXLOCAL_API_URL` (défaut `http://127.0.0.1:47367`) et `VOXLOCAL_API_TOKEN` dans l'environnement du processus dsh ; `cd plugins/voxlocal-tools && pnpm install && pnpm test`.
- **Feeder** : `VOXLOCAL_API_TOKEN=… python3 harness/ingest/dictation_feeder.py --backend dryrun|sdk [--once] [--seed-file f.txt]`. Chaque dictée terminée est livrée en *inject* (contexte durable, pas de tour) ; un *followup* (un tour) part sur une pause ≥ 20 s, une commande (« agent … ») ou une dictée finissant par « fin ». `state/state.json` garde le curseur : redémarrage sans rejeu ni trou.
- **SDK Python** : `deepseek-harness-sdk` n'est pas publié sur PyPI (vérifié le 25/09/2026). Le backend `sdk` l'importe s'il est installé (venv `harness/.venv`, ignoré par git) ; son protocole n'a que `session/prompt` (= followup), donc les injects attendent le followup suivant et partent dans un seul `run()`. Le backend `dryrun` écrit le JSONL de ce qui serait envoyé.
- **« Temps réel »** signifie aujourd'hui « par dictée terminée ». Les segments stabilisés pendant la parole arrivent avec H2b.

## Tests

```sh
python3 -m unittest harness.tests.test_feeder -v
(cd harness/plugins/voxlocal-tools && pnpm test)
```
