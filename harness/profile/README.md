# Profil `dsh` « scribe »

Composition `dsh` du harness clinique : les bundles livrés `@deepseek-ai/dsh-base` puis `@deepseek-ai/dsh-web-app` (la même pile que le profil `web`), puis la couche [`cordis.patch.yml`](cordis.patch.yml) de ce dossier.

## Contenu

| Fichier | Rôle |
|---|---|
| `package.json` | Manifeste du profil : `dsh.profile.bundles` et `@deepseek-ai/dsh` épinglé à `0.1.7-rc.2` |
| `pnpm-lock.yaml` | Verrou ; installer avec `pnpm install --frozen-lockfile` |
| `cordis.patch.yml` | Fournisseur `voxlocal-gpu` et modèle par défaut `qwen3.8-27b` |

`cordis.patch.yml` fait deux choses :

1. **`llm-pi-ai`** déclare le fournisseur `voxlocal-gpu` : protocole `openai-completions`, jeton lu dans `VOXLOCAL_LLM_TOKEN` à chaque requête (`apiKeyEnv`), URL lue dans `VOXLOCAL_LLM_URL` au démarrage (`!!js process.env.VOXLOCAL_LLM_URL`, même mécanisme que les bundles livrés), modèle `qwen3.8-27b` en entrée texte et image. `compat` force `max_tokens` et désactive le rôle `developer`, que `llama-server` n’accepte pas.
2. **`agent-default-model`** fait de `voxlocal-gpu / qwen3.8-27b` le modèle des nouvelles sessions.

Un patch `dsh` **remplace toute la config** de la ligne visée (pas de fusion). La ligne `llm-pi-ai` de `dsh-base` n’a pas de config, donc rien n’est perdu ; toute future modification doit reprendre l’intégralité des champs.

## Comment `dsh` trouve le profil

`dsh --profile <nom>` cherche `$DSH_HOME/profiles/<nom>/package.json`. [`../run-web.sh`](../run-web.sh) fixe `DSH_HOME=harness/.dsh-home` et y crée le lien `profiles/scribe → harness/profile`, pour que ce dossier suivi par git reste la seule source. Il fixe aussi `DSH_AGENTS_HOME=harness/.dsh-home/agents`, pour que les skills personnels de `~/.agents` de l’opérateur n’entrent pas dans le prompt de l’agent clinique. `dsh` réécrit à chaque démarrage un `cordis.yml` racine vide dans le profil ; il est ignoré par git.

## Vérifier la composition

```bash
cd harness/profile && pnpm install --frozen-lockfile
mkdir -p ../.dsh-home/profiles && ln -sfn "$PWD" ../.dsh-home/profiles/scribe
DSH_HOME="$PWD/../.dsh-home" ./node_modules/.bin/dsh --profile scribe --dump-config | grep -A18 'id: llm-pi-ai'
```

La sortie montre la ligne `llm-pi-ai` avec l’en-tête `# == @deepseek-ai/dsh-base, patched by …/profiles/scribe/cordis.patch.yml`.

## Tâche unique sans interface

Le profil livré `headless` accepte la même couche en surcouche `--patch`, ce qui donne le même fournisseur sans second fichier :

```bash
DSH_HOME="$PWD/harness/.dsh-home" DSH_AGENTS_HOME="$PWD/harness/.dsh-home/agents" \
  harness/profile/node_modules/.bin/dsh --profile headless \
  --patch "$PWD/harness/profile/cordis.patch.yml" --json "Bonjour"
```
