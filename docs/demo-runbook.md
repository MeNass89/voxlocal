# VoxLocal — démonstration de 90 secondes

Ce parcours montre le produit avec des données synthétiques. Ce n’est pas une
validation clinique : aucune voix de patient, aucun nom, aucune note réelle. Les
phrases à dicter sont fictives.

## Préparation (avant la démo, 10 minutes)

1. **Mac** (macOS 15 ou plus récent) : VoxLocal 2.3.0 construit depuis
   `mac/VoxLocal` (voir [`mac-build.md`](mac-build.md)), modèles Whisper et LLM
   installés (Réglages › Intelligence artificielle, « Détecté » en vert), mode
   actif **Medical**. Autorisations Microphone et Accessibilité accordées : sans
   Accessibilité, le texte est copié mais pas collé.
2. Ouvrir **TextEdit** avec un document vide, au premier plan à côté de
   VoxLocal : c’est l’application qui recevra le texte.
3. **iPhone** : Remote Scribe 1.3 installé par Xcode (Personal Team),
   autorisations Microphone et Réseau local accordées, même Wi-Fi que le Mac,
   onboarding déjà passé. Faire une dictée d’essai la veille.
4. Mettre l’iPhone en recopie d’écran (QuickTime › Nouvel enregistrement vidéo ›
   choisir l’iPhone) pour que la salle voie les deux écrans.
5. Garder à l’écran, pour le fallback : l’adresse IP du Mac
   (`ipconfig getifaddr en0`) et le code d’appairage affiché dans VoxLocal.

## Le script

| Temps | À l’écran | À dire |
|---|---|---|
| 0:00–0:10 | VoxLocal, écran **iPhone** : QR code, code d’appairage, empreinte TLS | « Un soignant dicte sur son iPhone. Le texte est produit ici, sur le poste de l’hôpital, pas dans un cloud. » |
| 0:10–0:25 | iPhone : toucher la carte du poste (ou le bouton de réglages), **Scanner le code du poste**, viser le QR ; la carte passe à « Connexion chiffrée prête. » ; le Mac liste l’iPhone sous « Appareils connectés » | « Un scan suffit : le code et l’empreinte du certificat du poste sont dans le QR. La connexion est chiffrée en TLS 1.3 et le téléphone refusera tout autre poste qui se ferait passer pour celui-ci. » |
| 0:25–0:45 | iPhone : **Démarrer la dictée**, dicter, **Arrêter la dictée** | Dicter : « Douleur thoracique apparue ce matin, sans irradiation. Tension artérielle quatorze huit. Pas de dyspnée. ECG de contrôle à prévoir. » |
| 0:45–0:60 | TextEdit : le texte mis en forme apparaît ; l’iPhone affiche la carte résultat surlignée et « Collé sur le poste » | « Whisper transcrit, un petit modèle de langage met en forme en mode médical, et le texte est collé dans le logiciel ouvert. Tout a tourné sur ce Mac. » |
| 0:60–0:75 | VoxLocal, écran **Dictées** : la dictée avec texte final et transcription brute | « Le poste garde la dictée : on peut la réécouter, comparer au brut, relancer. » |
| 0:75–0:90 | README du dépôt, section « Ce qui n’est pas encore fait » | « Ce qui reste est écrit noir sur blanc : signature Apple, enrôlement des appareils, validation DPO et clinique. Pour de gros modèles, un GPU privé est prêt côté code, sous contrat zéro rétention. » |

## Si quelque chose casse

- **Le QR ne se lit pas, ou le Wi-Fi bloque Bonjour.** Sur l’iPhone, dans les
  réglages de connexion (ou **Saisir l’adresse** si aucun poste n’est trouvé) : « Nom ou adresse IP du poste » = l’IP du Mac, port
  47365, « Code d’appairage requis » = le code affiché dans VoxLocal, TLS activé,
  **Rejoindre ce poste**. À la feuille « Vérifier l’identité du poste », montrer
  que l’empreinte est la même que sur le Mac, puis **Faire confiance et
  connecter**. C’est aussi une bonne démonstration de sécurité.
- **« Ce poste a déjà une empreinte différente. »** L’iPhone a épinglé un ancien
  certificat (VoxLocal réinstallé, dossier de données effacé). Réglages de
  connexion → **Oublier ce poste**, puis rescanner.
- **Aucun réseau commun.** Montrer la dictée directement sur le Mac : bouton
  **Dicter depuis ce Mac** de l’écran Dictées, même pipeline.
- **Le texte n’est pas collé.** L’autorisation Accessibilité manque : le texte
  est dans le presse-papier, faire Cmd-V dans TextEdit.

## Remise à zéro entre deux démos

1. iPhone : **Effacer** l’historique ; laisser « Conserver l’historique sur cet
   appareil » désactivé.
2. Mac : fermer VoxLocal et supprimer les dictées de démonstration dans
   `~/Library/Application Support/VoxLocal/data/history/` et
   `~/Library/Application Support/VoxLocal/remote-scribe/sessions/`. Ne pas
   toucher à `remote-scribe/tls/` : sinon l’empreinte change et l’iPhone
   refusera le poste jusqu’à « Oublier ce poste ».
3. Vider le document TextEdit.
4. Pour rejouer l’appairage complet : iPhone → **Oublier ce poste**, puis Mac →
   **Régénérer** le code. Le scan de la démo suivante repartira de zéro.

## En coulisses : l’API agent et le banc GPU

Ces deux parcours s’adressent à un public technique ; ils n’entrent pas dans les
90 secondes.

**API agent en loopback** (Python 3.11 ou plus récent, depuis la racine du
dépôt) :

```bash
export VOXLOCAL_AGENT_TOKEN='demo-token-local-16'
python3 -m agent.voxlocal_agent_api serve --mock
```

Dans un second terminal :

```bash
curl -sS -H "Authorization: Bearer $VOXLOCAL_AGENT_TOKEN" \
  http://127.0.0.1:47366/v1/capabilities
printf 'Texte synthétique de démonstration' | \
  python3 -m agent.voxlocal_agent_api clean --stdin --pretty
```

Le service reste en loopback, garde les requêtes en mémoire et signale le mode
mock. Le texte passé à `clean` vient de stdin pour ne pas apparaître dans la
liste des processus.

**Banc de mesure GPU.** Il ne contacte pas le control plane RunPod et ne dépense
aucun crédit. Une fois les URLs approuvées configurées :

```bash
export VOXLOCAL_VOICE_URL='https://voice.example'
export VOXLOCAL_LLM_URL='https://llm.example'
export VOXLOCAL_TOKEN_FILE=/chemin/vers/api-token
python3 cloud/runpod/benchmark.py --timeout 5 > benchmark.json
```

Il envoie de l’audio synthétique et un texte fixe, puis produit latences et
statuts sans imprimer de réponse du fournisseur. Le déploiement du Pod est décrit
dans [`docs/cloud-deployment.md`](cloud-deployment.md).
