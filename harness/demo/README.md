# Démo de bout en bout : parcours agent sur le portail enregistré

Une commande lance tout ce qu’il faut pour montrer le parcours du médecin sans iPhone ni accès au portail : une dictée arrive dans le chat de l’agent, l’agent prépare un brouillon par section avec des citations de la dictée, le médecin donne son feu vert, l’écriture part dans le portail (mock enregistré), puis le médecin fait annuler une modification.

Données synthétiques uniquement (patient fictif `pat-001`, dictée `harness/bridge/fixtures/transcript_entorse.txt`).

## Commandes

Depuis la racine du dépôt, sur macOS (Node ≥ 22.19, pnpm, Python ≥ 3.11) :

```bash
(cd harness/profile && pnpm install --frozen-lockfile)   # une fois : dsh épinglé 0.1.7-rc.2
bash harness/demo/run-demo.sh --check                     # prérequis seulement, sortie 0 si tout est prêt
bash harness/demo/run-demo.sh                             # lance la pile, imprime les URLs, Ctrl-C pour tout arrêter
```

Ouvrir l’URL `Chat du médecin (dsh web)` imprimée, cliquer **Continue** sur l’avertissement de préversion, coller le message (déjà dans le presse-papier sur macOS, sinon le fichier `Message à coller`), Entrée. Le déroulé à l’écran et le texte à dire sont dans [`docs/demo-runbook.md`](../../docs/demo-runbook.md#parcours-agent).

Rejouer le parcours sans navigateur visible et refaire les captures :

```bash
bash harness/demo/run-demo.sh --drive --shots docs/superpowers/evidence
```

`--drive` pilote le chat `dsh` dans `chrome-headless-shell` (Playwright) par le protocole DevTools ([`drive-ui.mjs`](drive-ui.mjs), sans dépendance npm), clique **Allow once** à chaque demande de feu vert, enregistre les cinq captures `2026-09-25-harness-demo-{dictation,draft,approval,applied,restore}.png`, imprime les écritures reçues par le portail, puis arrête tout.

## Ce que lance le script

Chaque exécution travaille dans un dossier temporaire neuf (journaux, audit, brouillons, état du portail mock, Harness home). Le script arrête tous les processus qu’il a démarrés en sortant, y compris sur Ctrl-C.

| Étape | Processus | Port |
|---|---|---|
| 1 | API agent VoxLocal en `--mock` (`agent/voxlocal_agent_api.py`) : la source de dictées quand aucun iPhone n’est dans la salle | 47366 |
| 2 | `harness/ingest/dictation_feeder.py --once --backend dryrun --seed-file … --patient-context pat-001` : déclare le patient, injecte la dictée, la livre une fois (le texte du fichier est remis en prose, comme VoxLocal la livre) | — |
| 3 | Pont portail `--backend mock` avec ses deux jetons, aléatoires à chaque exécution ; il vérifie chaque citation contre la dictée livrée (même identifiant, même patient, même rencontre) | 47368 |
| 4 | Le modèle (voir ci-dessous) | 47381 |
| 5 | `dsh` web, profil `scribe`, Harness home dans le dossier temporaire (aucune session des démos précédentes) | 3081 |

Options : `--provider scripted|local|pod`, `--seed-dictation FICHIER`, `--patient ID`, `--encounter ID`, `--port N` (web). `SCRIPTED_DELAY` règle la pause du modèle scripté avant chaque réponse (1,5 s par défaut, pour que la salle voie les étapes).

## Le modèle : `--provider`

| Valeur | Modèle | Usage |
|---|---|---|
| `scripted` (défaut) | [`scripted_provider.py`](scripted_provider.py) : le modèle scripté du test H4 ([`tests/test_loop.py`](../tests/test_loop.py)), étendu à l’annulation. Il appelle `record_find_sections`, deux `record_draft_edit` (examen clinique, orientation) avec citations exactes, `record_apply` sur chaque brouillon, puis `record_restore` quand le médecin écrit « Annulez… ». | La démo. Déroulé identique à chaque fois ; tout le reste (plugins, feu vert, pont, portail mock, audit) est réel. Il ne sait rédiger que la dictée entorse. |
| `local` | `llama-server` local (`LLAMA_SERVER`, défaut `/tmp/vox-w2-3-build/llama/bin/llama-server`) avec un GGUF (`VOXLOCAL_LOCAL_MODEL`, défaut Qwen2.5-0.5B Q4_K_M) | Vérifier le branchement d’un vrai modèle. Le 0,5B ne suit pas le protocole d’outils : il n’atteint pas le brouillon (mesuré dans [`bench/`](../bench/README.md)). |
| `pod` | **Qwen3.8-27B** sur le GPU loué (RunPod), via la passerelle OpenAI-compatible | La cible réelle. `VOXLOCAL_LLM_URL=https://<pod>:8443/llm/v1 VOXLOCAL_LLM_TOKEN=… bash harness/demo/run-demo.sh --provider pod` |

## Ce qui est réel, ce qui ne l’est pas encore

- Réels : `dsh` 0.1.7-rc.2, les quatre plugins du profil `scribe`, la porte de feu vert (`ask`), le relais de décision au pont par le jeton approbateur, le pont (brouillons immuables, feu vert à usage unique, empreintes, restauration), les deux journaux d’audit, le feeder et l’API de dictées en mode mock.
- Simulés : le modèle (`scripted`), le portail (mock enregistré), l’iPhone (dictée injectée).
- Écart connu : le feeder n’écrit pas encore dans une session `dsh` web (le SDK n’a que `session/prompt` et aucun webhook ne crée un message dans une session existante). Il livre la dictée au format exact du chat (`--backend dryrun`) et la démo la colle dans le chat. Même texte, même identifiant de dictée.
- Écart connu : le pont vérifie les citations contre un dossier de dictées ; la démo y dépose la dictée livrée. Brancher le pont directement sur l’API de dictées reste à faire.
- Les appels `record_*` s’affichent dans le chat comme des lignes d’outil génériques (entrée / sortie). Le client web `dsh` choisit ses cartes côté navigateur par nom d’outil et ignore `presentCall` / `presentResult` des plugins ; une carte diff dédiée demanderait un plugin client (`tool.call.toolview`).

## Fichiers

| Fichier | Rôle |
|---|---|
| `run-demo.sh` | Prérequis (`--check`), lancement de la pile, arrêt propre, pilotage (`--drive`) |
| `scripted_provider.py` | Modèle scripté OpenAI-compatible (réutilise celui de `tests/test_loop.py`) |
| `drive-ui.mjs` | Pilote du chat `dsh` par CDP : envoi, feu vert, captures |
