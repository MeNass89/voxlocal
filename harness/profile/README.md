# Profil `dsh` « scribe »

Composition `dsh` du harness clinique : les bundles livrés `@deepseek-ai/dsh-base` puis `@deepseek-ai/dsh-web-app` (la même pile que le profil `web`), puis la couche [`cordis.patch.yml`](cordis.patch.yml) de ce dossier.

## Contenu

| Fichier | Rôle |
|---|---|
| `package.json` | Manifeste du profil : `dsh.profile.bundles` et `@deepseek-ai/dsh` épinglé à `0.1.7-rc.2` |
| `pnpm-lock.yaml` | Verrou ; installer avec `pnpm install --frozen-lockfile` |
| `cordis.patch.yml` | Fournisseur `voxlocal-gpu`, modèle par défaut, persona neutralisée, politique d’approbation `ask`, preset `scribe`, les quatre plugins VoxLocal |

`cordis.patch.yml` fait ceci :

1. **`llm-pi-ai`** déclare le fournisseur `voxlocal-gpu` : protocole `openai-completions`, jeton lu dans `VOXLOCAL_LLM_TOKEN` à chaque requête (`apiKeyEnv`), URL lue dans `VOXLOCAL_LLM_URL` au démarrage (`!!js process.env.VOXLOCAL_LLM_URL`, même mécanisme que les bundles livrés), modèle `qwen3.8-27b` en entrée texte et image. `compat` force `max_tokens` et désactive le rôle `developer`, que `llama-server` n’accepte pas.
2. **`agent-default-model`** fait de `voxlocal-gpu / qwen3.8-27b` le modèle des nouvelles sessions.
3. **`system-prompt`** vide la persona « coding agent » livrée ; le plugin `scribe-persona` apporte le rôle et les règles.
4. **`approval`** fixe la politique `ask` : `record_apply` et `record_restore` attendent le feu vert du médecin dans le chat.
5. **Presets** : les presets de code livrés (`standard`, `ptc`, `minimal`, `cordis`) sont désactivés ; les sessions utilisent le preset `scribe` (« Scribe clinique »), sans terminal, fichiers ni sous-agents.
6. **Quatre lignes `insert`** montent `@voxlocal/dsh-voxlocal-tools`, `@voxlocal/portail-tools`, `@voxlocal/scribe-approval` et `@voxlocal/scribe-persona`.

## Monter un plugin local

Les plugins de `harness/plugins/*` sont des dépendances `link:` de ce profil (`package.json`), installées par `pnpm install --frozen-lockfile`, et les lignes du patch nomment le **paquet**, pas un chemin. Deux autres voies ont été essayées :

- un chemin relatif dans `cordis.patch.yml` se résout à côté du lien `$DSH_HOME/profiles/scribe`, pas à côté du fichier suivi : l’import échoue ;
- `dsh plugin --profile scribe add file:…` réécrit ce `package.json` et exige une déclaration `dsh.bundle` : inutile pour un dépôt qui suit déjà le profil.

Chaque plugin déclare les paquets `@deepseek-ai/*` (et `schemastery`) en `peerDependencies` : au démarrage, `dsh` les résout depuis sa propre installation, donc un seul exemplaire de `cordis` et des services. `dsh` charge le TypeScript des plugins avec le mode « strip-only » de Node : pas de propriétés de paramètre (`constructor(private readonly x)`), pas d’`enum`.

Un patch `dsh` **remplace toute la config** de la ligne visée (pas de fusion). La ligne `llm-pi-ai` de `dsh-base` n’a pas de config, donc rien n’est perdu ; toute future modification doit reprendre l’intégralité des champs.

## Comment `dsh` trouve le profil

`dsh --profile <nom>` cherche `$DSH_HOME/profiles/<nom>/package.json`. [`../run-web.sh`](../run-web.sh) fixe `DSH_HOME=harness/.dsh-home` et y crée le lien `profiles/scribe → harness/profile`, pour que ce dossier suivi par git reste la seule source. Il fixe aussi `DSH_AGENTS_HOME=harness/.dsh-home/agents`, pour que les skills personnels de `~/.agents` de l’opérateur n’entrent pas dans le prompt de l’agent clinique. `dsh` réécrit à chaque démarrage un `cordis.yml` racine vide dans le profil ; il est ignoré par git.

## Vérifier la composition

```bash
cd harness/profile && pnpm install --frozen-lockfile
mkdir -p ../.dsh-home/profiles && ln -sfn "$PWD" ../.dsh-home/profiles/scribe
DSH_HOME="$PWD/../.dsh-home" ./node_modules/.bin/dsh --profile scribe --dump-config | grep -A18 'id: llm-pi-ai'
```

La sortie montre la ligne `llm-pi-ai` avec l’en-tête `# == @deepseek-ai/dsh-base, patched by …/profiles/scribe/cordis.patch.yml`. Pour les plugins et la politique : `… --dump-config | grep -B1 -A8 'id: approval$\|id: scribe-\|id: portail-tools\|id: voxlocal-tools'`.

## Tâche unique sans interface

Le profil livré `headless` ne voit pas les paquets `@voxlocal/*` (ils sont liés dans le `node_modules` de ce profil-ci). Pour un run sans interface, [`../tests/test_loop.py`](../tests/test_loop.py) crée un profil jetable `scribe-loop` (bundles `dsh-base` + `dsh-headless`, ce `cordis.patch.yml` copié, les quatre plugins liés dans son `node_modules`) et ajoute une surcouche de test qui coupe les outils de code que le bundle `headless` monte globalement. Sans interface, personne ne répond au feu vert : la politique `ask` échoue fermée (aucune écriture).
