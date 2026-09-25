# Harness clinique VoxLocal

Le médecin dicte en se déplaçant ; VoxLocal transcrit et nettoie en temps réel ; un agent sur le poste reçoit la dictée, prépare les modifications du dossier patient et **attend un feu vert explicite** avant d’écrire quoi que ce soit dans le portail.

Le harness est [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`, MIT), épinglé à **`@deepseek-ai/dsh` 0.1.7-rc.2** (commit `477b4f4`). `dsh` est une préversion développeur qui casse souvent : la version exacte est figée dans [`profile/package.json`](profile/package.json) et dans `profile/pnpm-lock.yaml`. Ne la changer qu’avec une revue du profil.

Plan de la vague 3 : [`docs/superpowers/plans/2026-09-25-voxlocal-wave3-harness.md`](../docs/superpowers/plans/2026-09-25-voxlocal-wave3-harness.md).

## État

| Brique | Dossier | État |
|---|---|---|
| Profil `scribe` + fournisseur GPU | [`profile/`](profile/README.md) | H1 fait |
| Banc d’appel d’outils | [`bench/`](bench/README.md) | H1 fait |
| Flux de dictée (`voxlocal-tools`, feeder) | `plugins/voxlocal-tools/`, `ingest/` | H2 |
| Pont portail + mock enregistré (`portail-tools`) | `bridge/`, `plugins/portail-tools/` | H3 |
| Feu vert, audit, persona | `plugins/scribe-approval/`, `plugins/scribe-persona/` | H4 |
| Démo de bout en bout | — | H5 |
| Lanceur Windows, CI | — | H6 |

## Lancer l’interface web (macOS, développement)

Prérequis : Node ≥ 22.19, pnpm.

```bash
export VOXLOCAL_LLM_URL='https://<pod>:8443/llm/v1'   # passerelle OpenAI-compatible, se termine par /v1
export VOXLOCAL_LLM_TOKEN='…'                        # jeton de la passerelle GPU, jamais dans git
harness/run-web.sh                                   # dsh --profile scribe --no-open
```

Le script installe `dsh` au verrou près (`pnpm install --frozen-lockfile`), place le Harness home dans `harness/.dsh-home/` (ignoré par git), y relie le profil `scribe`, puis imprime une ligne `dsh web: http://127.0.0.1:3080/?token=…`. Ouvrir cette URL dans le navigateur du poste. Les options suivantes vont à l’app web (`--port 3081`, par exemple).

## Posture de sécurité

- **Aucune donnée patient** dans ce dossier : fixtures et dictées de test synthétiques.
- **Secrets hors git** : le jeton GPU vient de `VOXLOCAL_LLM_TOKEN` (`apiKeyEnv` de `dsh`), l’URL de `VOXLOCAL_LLM_URL`. Les identifiants du portail ne seront lus que par le pont (H3), jamais par le processus `dsh`.
- **Écoute locale seulement** : l’interface web `dsh` n’écoute que sur la boucle locale et refuse `--host 0.0.0.0` ; l’URL de démarrage porte un jeton de processus.
- **Feu vert dans le harness** : toute écriture au dossier passera par la porte d’approbation `dsh` (H4) et sera journalisée.
