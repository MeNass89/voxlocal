# Plan de runtime d'agents VoxLocal / RunPod

Ce document décrit la cible d'architecture sans déployer RunPod et sans inventer d'URL. Les noms `voice`, `clean` et `llm` désignent des capacités ; leurs endpoints réels seront enregistrés uniquement après approbation de l'hôpital et création du compte RunPod.

## Flux par poste

```text
Agent local (harness)
        |
        | loopback HTTP, Bearer local, JSONL/JSON
        v
voxlocal-agent-api (service Windows/macOS)
        |
        | policy + capacité bornée + timeouts + ZDR
        +--> voice endpoint HTTPS approuvé (modèle vocal)
        +--> clean endpoint HTTPS approuvé (petit modèle, optionnel)
        +--> llm endpoint HTTPS approuvé (Qwen 3.x, optionnel)
                 |
                 +--> RunPod privé / réseau approuvé
```

Le harness ne reçoit jamais les tokens RunPod. Il appelle seulement `voxlocal-agent-api`; le service garde les secrets dans le coffre du système ou l'environnement du service. Une requête de nettoyage reçoit toujours le texte brut et le résultat séparément, afin que l'agent puisse demander une relecture humaine. Les modèles sont sélectionnés séparément par `VOXLOCAL_VOICE_MODEL`, `VOXLOCAL_CLEAN_MODEL` et `VOXLOCAL_LLM_MODEL`.

## Policy et file

Chaque capacité a une policy distincte : taille maximale, délai, nombre de tentatives et endpoint autorisé. La capacité de traitement est bornée en mémoire ; en cas de saturation, l'API refuse immédiatement avec `server_busy` et `retryable=true` (le harness peut maintenir sa propre file chiffrée si la politique l'autorise). Les tâches vocales ne sont jamais exécutées deux fois après `completed`. Les tâches LLM peuvent porter un `idempotencyKey` interne, sans mettre de PHI dans les logs. Le service refuse les nouvelles tâches et efface les buffers lors de l'arrêt.

La passerelle livrée commence avec une capacité globale de 4 appels simultanés (réglable de 1 à 16 par `--max-concurrent`) ; la séparation fine 1 transcription, 2 nettoyages, 1 chat reste une étape de benchmark. Les timeouts distants sont de 120 secondes par défaut et les retries doivent rester limités aux connexions/503 avec backoff borné. Ces valeurs seront ajustées après mesure sur les modèles réels.

## Déploiement RunPod à préparer

Le Pod de test existant démarre actuellement avec `bash /workspace/voxlocal/start-all.sh`. Le token de test est lu à l'intérieur du Pod par `cat /workspace/voxlocal/api-token`. Ces deux commandes sont un bootstrap distant ; elles ne doivent pas être exécutées sur les postes de l'hôpital, et le contenu de `api-token` ne doit jamais être copié dans le dépôt, le harness ou les logs. Le futur adaptateur RunPod devra seulement vérifier que les services lancés par `start-all.sh` exposent les routes HTTPS attendues, avec un secret distinct côté poste et une rotation gérée par l'administrateur.

1. Créer trois services privés séparés (ou trois workers avec routes strictes) : voix, correction, LLM.
2. Pour chacun, enregistrer région, image, modèle, URL HTTPS, certificat, limites, journaux et DPA/ZDR ; ne pas réutiliser le token voix pour le LLM.
3. Exiger `store=false`/équivalent, désactiver l'entraînement fournisseur, limiter les logs de requêtes et vérifier la suppression des volumes temporaires.
4. Mettre les tokens dans le coffre Windows (Credential Manager/DPAPI) ou le secret store macOS, puis injecter une variable au service sans la copier dans un prompt ou un fichier Git.
5. Tester la latence, la panne réseau, la reprise, la saturation et la suppression des données avec des voix synthétiques avant le pilote clinique.

Aucune URL RunPod ne doit être codée dans le dépôt. Une future commande `voxlocal-agent doctor --remote` pourra seulement afficher l'état/capacité, jamais le token ni le corps des requêtes. Le serveur local ne tente pas de lancer `start-all.sh` à distance : cette opération nécessite l'authentification et le contrôle d'exploitation RunPod.

## Offline et reprise

Sans réseau, le service peut encore fournir `clean` en mode `offline-safe` (normalisation d'espaces) et signaler la perte de la capacité vocale/LLM. Il ne doit pas prétendre avoir transcrit. Le harness peut conserver une file locale chiffrée uniquement si le DPO l'autorise ; le comportement par défaut est de refuser et demander une nouvelle dictée plutôt que de persister de l'audio patient.

## Santé et observabilité

`/healthz`, `/v1/status` et `/v1/capabilities` ne renvoient que l'état, les capacités et des compteurs. Les métriques recommandées sont latence par capacité, erreurs par code, saturation de file et disponibilité, sans texte, audio, patient ID, URL secrète ni prompt. Un service Windows doit redémarrer avec backoff et produire une alerte si la configuration TLS, le token ou le certificat devient invalide.

## Ordre de mise en œuvre

Le prototype livre déjà le contrat local et un mock déterministe. La prochaine étape est un adaptateur de secret store Windows/macOS, puis l'enrôlement TLS/mTLS et enfin la connexion à des endpoints RunPod fournis par l'administrateur. Le choix précis du modèle Qwen et la taille 27B/35B doivent rester une décision de benchmark (VRAM, latence et politique de données), pas une valeur supposée par le client.
