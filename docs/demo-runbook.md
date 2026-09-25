# VoxLocal — démonstration reproductible

Ce parcours montre le produit avec des données synthétiques. Il ne constitue
pas une validation clinique et ne doit pas recevoir une voix, un nom ou une
note de patient.

## 1. Montrer le poste local

Depuis la racine du projet, le runtime agent du DMG peut être démarré en
loopback avec Python 3.11 ou plus récent :

```bash
export VOXLOCAL_AGENT_TOKEN='demo-token-local-16'
export VOXLOCAL_PYTHON=/opt/homebrew/bin/python3
LAUNCH=/Applications/VoxLocal.app/Contents/Resources/Agent/bin/voxlocal-agent
"$LAUNCH" serve --mock
```

Dans un second terminal :

```bash
curl -sS -H "Authorization: Bearer $VOXLOCAL_AGENT_TOKEN" \
  http://127.0.0.1:47366/v1/capabilities
printf 'Texte synthétique de démonstration' | \
  "$LAUNCH" clean --stdin --pretty
```

Le service reste loopback, garde les requêtes en mémoire et signale le mode
mock. Le texte passé à `clean` vient de stdin afin de ne pas apparaître dans la
liste des processus.

## 2. Montrer la séparation des capacités

Le benchmark ne contacte jamais le control plane RunPod et ne dépense aucun
crédit GPU. Une fois les URLs approuvées configurées dans l’environnement :

```bash
export VOXLOCAL_VOICE_URL='https://voice.example'
export VOXLOCAL_CLEAN_URL='https://clean.example'
export VOXLOCAL_LLM_URL='https://llm.example'
export VOXLOCAL_TOKEN_FILE=/workspace/voxlocal/api-token
python3 cloud/runpod/benchmark.py --timeout 5 > benchmark.json
```

Il envoie un WAV silencieux déterministe et un texte fixe, puis produit les
latences et statuts sans imprimer de réponse fournisseur. Une erreur de modèle,
de certificat ou de route apparaît comme un résultat ciblé, pas comme une
réponse clinique inventée.

## 3. Montrer le parcours iPhone → poste

Dans Xcode, sélectionner la Personal Team, l’iPhone apparié et le scheme
`RemoteScribePortable`, puis lancer l’application. Sur l’iPhone, accorder
Microphone et Réseau local. Dans VoxLocal sur le Mac, sélectionner le serveur
appairé et saisir le code affiché ; Bonjour sert uniquement à trouver un
candidat, jamais à prouver son identité.

Le bouton de dictée est l’action principale. La transcription reste lisible
sur une surface stable, tandis que les actions de connexion, partage et reprise
utilisent les composants Liquid Glass natifs d’iOS 26 avec fallback iOS 16.

## 4. Message à présenter

VoxLocal sépare quatre décisions qui sont souvent mélangées :

1. le poste contrôle l’interface et le coffre de secrets ;
2. la passerelle agent expose un contrat local simple aux harness ;
3. la voix, le nettoyage et le LLM sont des capacités indépendantes et
   benchmarkées ;
4. aucune promesse ZDR/RGPD n’est faite pour un fournisseur tant que sa région,
   rétention, journalisation, DPA et procédure de suppression ne sont pas
   vérifiées.

Le DMG macOS est signé ad hoc pour les essais. La signature iOS de distribution,
la notarisation Mac, l’installateur Windows et la validation DPO restent les
étapes de mise sur le marché.
