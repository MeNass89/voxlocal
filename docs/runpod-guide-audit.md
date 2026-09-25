# RunPod agent setup audit

Source: https://docs.runpod.io/get-started/agent-skills (official RunPod docs; last modified 2026-08-19). The user-provided `/agent-setup.md` URL is not reachable, but the current official page is the Agent skills guide.

## Required setup

1. Install the skills plugin/router for the coding agent:
   `npx skills add runpod/runpod-plugins-official`
2. Install `runpodctl` if absent:
   `curl -sSL https://cli.runpod.net | bash` or `brew install runpod/runpodctl/runpodctl`.
3. Authenticate with a RunPod API key. For the current shell: `export RUNPOD_API_KEY=<key>`; persist in `~/.zshrc`/`~/.bashrc`, or run `runpodctl doctor` to save it in `~/.runpod/config.toml`.
4. Restart the agent and verify with a read-only request such as “List my Runpod endpoints”.

The same API key is used by runpodctl, Flash, and the bundled MCP server. Never commit or paste the real key into source/config tracked by git.

## Agent/MCP wiring

- Codex native marketplace: `codex plugin marketplace add https://github.com/runpod/runpod-plugins-official.git`; then `codex /plugins`, Runpod tab, install/reload.
- If MCP tools are missing: `codex mcp add runpod --transport http https://mcp.getrunpod.io/`.
- Generic guided MCP installer: `npx @runpod/mcp-server@latest add`; it authenticates interactively. Alternatively pass `Authorization: Bearer $RUNPOD_API_KEY` as an HTTP header.

The plugin includes a router plus `runpod-mcp`, `runpodctl`, `flash`, `companion-clis`, `runpod-usage`, and `runpod-migrate` skills. It can create/list/manage Pods, endpoints, templates, volumes, registries, billing, file transfers/SSH, Flash deployments, and API migration.

## Parameters/env

Only explicitly required environment variable is `RUNPOD_API_KEY`; value is the user's API key. The guide does not specify additional required env vars for initial setup. MCP HTTP URL is `https://mcp.getrunpod.io/`. `runpod-migrate` accepts optional `[scope: all | rest | graphql] [path]`, defaulting to `all` and current directory.

## Vérification dans cette session

Le binaire `codex` présent est `codex-cli 0.156.1`. La syntaxe locale attend
`codex mcp add runpod --url https://mcp.getrunpod.io/` plutôt que l’ancienne
forme `--transport http` du guide. Les deux tentatives ont toutefois échoué
avant l’écriture de configuration avec `Model provider local_codex_proxy not
found`. Le marketplace/MCP RunPod n’est donc pas déclaré comme connecté.

Après correction de la configuration du client Codex, l’action utilisateur
requise reste : ouvrir le marketplace **RunPod**, installer le plugin, recharger
Codex, puis effectuer l’OAuth RunPod. Il faudra ensuite vérifier en lecture seule
la liste des Pods/endpoints. Aucun secret n’a été enregistré par cette session.
