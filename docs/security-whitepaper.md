# Livre blanc sécurité — VoxLocal / Remote Scribe

Version du 25 septembre 2026, pour VoxLocal.app 2.3.0 (build 5), Remote Scribe
iOS 1.3 (build 4) et l’hôte Python de référence. Ce document s’adresse au RSSI,
au DPO et à l’équipe informatique d’un hôpital. Chaque affirmation renvoie au
fichier qui l’implémente, pour que vous puissiez la vérifier vous-même. Il ne
constitue ni une homologation ni une déclaration de conformité RGPD : la
dernière section liste ce que votre établissement doit encore valider.

**Ce que fait le produit.** Un soignant dicte sur un iPhone ou un iPad. L’audio
part vers un poste de l’hôpital (Mac avec VoxLocal, ou Windows/macOS avec
l’hôte Python). Le poste transcrit avec Whisper, réécrit le texte avec un
modèle de langage selon un « mode » (par exemple Medical), puis le colle dans
l’application ouverte sur le poste. L’inférence tourne sur le poste par défaut ;
un GPU privé est une option.

**Modèle de menace.** Les menaces retenues sont les suivantes :

1. un tiers sur le même Wi-Fi ou VLAN qui écoute le trafic, se fait passer pour
   un poste ou rejoue un appairage ;
2. un appareil non autorisé qui tente de deviner le code d’appairage ;
3. un autre compte ou processus local du poste qui lit les secrets ou les
   arguments de processus ;
4. une fuite de contenu clinique par les journaux, les messages d’erreur ou le
   dépôt de code ;
5. un fournisseur GPU qui conserve, journalise ou réutilise l’audio et le texte.

Hors périmètre à ce stade : un poste déjà compromis au niveau administrateur,
un iPhone déverrouillé et volé, une autorité de certification de l’hôpital
compromise, et les attaques physiques. Ces risques relèvent de la gestion du
parc (MDM, FileVault/BitLocker, comptes) et sont repris dans la dernière
section.

## Flux de données

```text
[iPhone / iPad]  Remote Scribe (ios/)
  micro -> PCM s16le mono 16 kHz -> trames Remote Scribe v1
        |
        |  TLS 1.3, port 47365, certificat du poste épinglé
        |  découverte Bonjour _remotescribe._tcp (indicative, jamais une preuve)
        v
[Poste de l'hôpital]
  macOS : VoxLocal.app (mac/VoxLocal) + RemoteScribeCore (RemoteScribe/)
          whisper-cli ; llama-server sur 127.0.0.1, port aléatoire, clé aléatoire
  Windows ou macOS : server/voxlocal_server.py, sans persistance applicative
        |
        |  texte final : collé dans l'application active et/ou presse-papier du poste
        |  statut et texte renvoyés à l'iPhone dans la même connexion TLS
        |
        +--(option)--> GPU privé en HTTPS avec jeton
                       /v1/audio/transcriptions, /v1/chat/completions
```

Étapes, dans l’ordre réel :

1. **Découverte.** Le poste publie `_remotescribe._tcp` en Bonjour, avec
   l’empreinte de son certificat dans l’enregistrement TXT `fp`
   ([`RemoteServer.swift`](../RemoteScribe/Core/Sources/RemoteServer.swift),
   [`voxlocal_server.py`](../server/voxlocal_server.py)). L’iPhone affiche les
   postes trouvés comme de simples candidats : il ne se connecte jamais
   automatiquement à un service découvert, sauf à celui dont le nom figure dans
   un QR code d’appairage scanné sur l’écran du poste
   ([`PortableClientModel.swift`](../ios/RemoteScribePortable/PortableClientModel.swift)).
2. **Connexion et identité.** La poignée de main TLS 1.3 vérifie l’empreinte du
   certificat avant tout octet applicatif (voir [Transport](#transport)).
3. **Appairage.** L’iPhone envoie le code d’appairage dans la connexion
   chiffrée. Sans code valide, le poste refuse la session.
4. **Dictée.** L’iPhone envoie l’audio en trames de 1 Mio maximum, numérotées
   par session ; le poste vérifie la contiguïté des numéros et, à l’arrêt, que
   le nombre d’échantillons annoncé (`framesSent`) égale le nombre reçu
   ([`SessionHandler.swift`](../RemoteScribe/Core/Sources/SessionHandler.swift),
   [`AudioReceiver.swift`](../RemoteScribe/Core/Sources/AudioReceiver.swift)).
   Le contrat complet est dans
   [`protocol-reconstruction.md`](protocol-reconstruction.md).
5. **Traitement sur le poste.** Sur Mac, `whisper-cli` transcrit le WAV, puis
   `llama-server` réécrit le texte selon le mode actif
   ([`RemoteScribeIntegration.swift`](../mac/VoxLocal/Sources/VoxLocal/RemoteScribeIntegration.swift),
   [`Engines.swift`](../mac/VoxLocal/Sources/VoxLocal/Engines.swift),
   [`LLMServer.swift`](../mac/VoxLocal/Sources/VoxLocal/LLMServer.swift)).
   `llama-server` écoute uniquement sur `127.0.0.1`, sur un port attribué par
   le noyau, et exige une clé tirée au hasard à chaque démarrage. Avant de lui
   confier cette clé, VoxLocal vérifie avec `lsof` que le port écoute bien sous
   le PID du processus qu’il vient de lancer ; sinon il l’arrête et signale
   « le port de llama-server a été pris par un autre processus ». Les mesures
   sont dans [`mac-performance.md`](mac-performance.md).
6. **Restitution.** Le texte final est collé dans l’application active du poste
   et/ou laissé dans le presse-papier, selon les réglages de VoxLocal. Le statut
   et le texte reviennent à l’iPhone dans la même connexion.
7. **GPU privé (option).** Si l’établissement choisit le calcul « GPU cloud »
   sur Mac, ou configure `VOXLOCAL_GPU_URL` sur l’hôte Python, le poste envoie
   le WAV et le texte à un endpoint compatible OpenAI en HTTPS
   ([`CloudGPU.swift`](../mac/VoxLocal/Sources/VoxLocal/CloudGPU.swift),
   [`voxlocal_server.py`](../server/voxlocal_server.py)). Voir
   [Fournisseur GPU](#fournisseur-gpu).

Le contenu clinique ne transite donc que par l’iPhone, le réseau local chiffré,
le poste et, si vous l’activez, le GPU privé. Aucun service de VoxLocal ne
reçoit de copie.

Un second flux, indépendant, sert les harness d’agents IA locaux : une API HTTP
sur `127.0.0.1:47366` avec jeton Bearer, sans persistance
([`agent-api.md`](agent-api.md)). Elle refuse d’écouter hors loopback et exige
HTTPS pour tout moteur distant.

## Transport

**TLS 1.3 minimum, partout.** Le serveur Swift fixe la version minimale à
TLS 1.3 ([`RemoteServer.swift`](../RemoteScribe/Core/Sources/RemoteServer.swift)),
tout comme l’hôte Python (`ssl.TLSVersion.TLSv1_3` dans
[`voxlocal_server.py`](../server/voxlocal_server.py)) et le client iOS
([`ios/Core/Sources/RemoteClient.swift`](../ios/Core/Sources/RemoteClient.swift)).
VoxLocal.app n’écoute jamais en clair : sans identité TLS disponible, le
serveur ne démarre pas.

**Identité du poste.** Chaque poste possède un certificat RSA 2048 auto-signé,
valable 3650 jours, avec les SAN `<hôte>.local`, `localhost` et `127.0.0.1`.
VoxLocal le crée au premier lancement avec `/usr/bin/openssl`
([`TLSIdentity.swift`](../RemoteScribe/Core/Sources/TLSIdentity.swift)) ; pour
l’hôte Python, [`scripts/make-tls-identity.sh`](../scripts/make-tls-identity.sh)
(macOS, Linux) et [`windows/new-tls-identity.ps1`](../windows/new-tls-identity.ps1)
produisent le même certificat. Un certificat émis par la CA de l’hôpital peut le
remplacer (`--tls-cert` / `--tls-key`, ou `-TlsCert` / `-TlsKey` sous Windows).

**macOS 15 minimum.** VoxLocal importe l’identité avec l’option
`kSecImportToMemoryOnly` : la clé reste en mémoire et n’entre pas dans le
trousseau de session. Cette option n’existe qu’à partir de macOS 15 ; sur
macOS 13 et 14, l’import PKCS#12 peut déposer l’identité dans le trousseau
`login`. VoxLocal et `RemoteScribeCore` exigent donc macOS 15 ou plus récent
([`Package.swift`](../mac/VoxLocal/Package.swift),
[`Info.plist`](../mac/VoxLocal/App/Info.plist), `LSMinimumSystemVersion` 15.0).
Prévoyez des Mac sous macOS 15 ou plus récent pour un pilote.

**Épinglage du certificat.** L’empreinte est le SHA-256 du certificat feuille au
format DER (le certificat, pas la clé publique SPKI). VoxLocal l’affiche en
hexadécimal par groupes de 4 dans son écran iPhone ; le QR code et Bonjour la
portent en base64. Sur l’iPhone, la décision est prise dans le bloc de
vérification TLS, pendant la poignée de main : une identité refusée n’atteint
jamais l’état « connecté », donc aucun code d’appairage ni aucun échantillon
audio ne quitte le téléphone ([`ios/Core/Sources/RemoteClient.swift`](../ios/Core/Sources/RemoteClient.swift),
[`ios-stability.md`](ios-stability.md)).

- **Première connexion.** Si le certificat est reconnu par une CA installée sur
  l’iPhone (profil MDM de l’hôpital), il est accepté sans épinglage et la CA
  reste maîtresse de la rotation. Sinon, l’iPhone affiche « Vérifier l’identité
  du poste » avec l’empreinte : l’utilisateur la compare à celle de l’écran du
  poste, puis choisit « Faire confiance et connecter » ou « Annuler ».
- **QR code.** Le QR code affiché par VoxLocal contient le nom du poste, le code
  d’appairage et l’empreinte (`remotescribe://pair?name=…&code=…&fp=…`). Il est
  analysé strictement ([`PairingLink.swift`](../ios/RemoteScribePortable/PairingLink.swift),
  tests dans [`PairingLinkTests.swift`](../ios/RemoteScribePortableTests/PairingLinkTests.swift)).
  Il épingle l’empreinte à la première utilisation. **Il ne remplace jamais une
  empreinte différente déjà épinglée** : l’app répond « Ce poste a déjà une
  empreinte différente. Oubliez d’abord « nom » dans les réglages de connexion,
  puis rescannez. » et ne modifie rien, car n’importe qui peut imprimer un QR
  code (`PortableClientModel.pinConflict` dans
  [`PortableClientModel.swift`](../ios/RemoteScribePortable/PortableClientModel.swift)).
- **Changement de certificat.** Un poste épinglé qui présente un autre
  certificat est refusé : « L’identité du poste a changé. Vérifiez-le avant de
  réessayer. » Après un changement légitime, l’utilisateur choisit « Oublier ce
  poste » puis vérifie la nouvelle empreinte.

**Code d’appairage.** Il est obligatoire sur tous les hôtes. VoxLocal le génère
(8 caractères aléatoires, affichés `XXXX-XXXX`), le range dans le trousseau et permet de le régénérer.
L’hôte Python exige 12 caractères au moins dès qu’un GPU réel est configuré et
compare le code en temps constant (`hmac.compare_digest`). Le code est envoyé
dans la connexion TLS, jamais en clair.

**Verrouillage après échecs.** Sur le serveur Swift, 5 échecs d’appairage depuis
une même adresse dans une fenêtre de 10 minutes bloquent cette adresse pendant
60 s ; les autres appareils continuent à s’appairer
([`PairingGate.swift`](../RemoteScribe/Core/Sources/PairingGate.swift), tests
dans [`RemoteScribeCoreTests.swift`](../RemoteScribe/Core/Tests/RemoteScribeCoreTests.swift)).
L’hôte Python refuse une adresse qui compte 5 échecs dans les 60 dernières
secondes, ajoute 0,4 s de délai à chaque échec, et limite à 8 connexions
simultanées dont 2 par adresse.

**Mode non chiffré.** Il n’existe que pour les tests synthétiques : l’hôte Python
l’exige explicitement avec `--mock --insecure-test-only`, l’hôte CLI Swift avec
`--insecure-plaintext`, et l’app iOS ne l’accepte que vers `localhost`,
`127.0.0.0/8` ou `::1`. Un poste découvert par Bonjour exige toujours TLS.

**Ce qui n’est pas livré.** Le certificat client (mTLS) : l’hôte Python accepte
`--tls-client-ca`, mais l’app iPhone ne présente aucune identité client
aujourd’hui ; activer cette option avant l’enrôlement MDM des iPhones fait
échouer la connexion. L’enrôlement et la révocation individuelle des appareils
restent à construire avec la CA et le MDM de l’hôpital. D’ici là, un appareil
qui connaît le code d’appairage peut se connecter ; régénérer le code révoque
l’accès de tous les appareils à la fois.

## Données au repos

**Hôtes Python : aucune persistance applicative.** L’audio reste dans un tampon
mémoire, supprimé après l’inférence ; aucun WAV ni texte n’est écrit sur disque.
Le serveur l’annonce au démarrage (`persistence=false`)
([`voxlocal_server.py`](../server/voxlocal_server.py)). La mémoire Python n’offre
pas de garantie d’effacement physique ; la durée et la taille des sessions sont
plafonnées (10 minutes d’audio par session).

**VoxLocal sur Mac : un historique local, par conception.** Le produit garde
chaque dictée pour permettre la relecture et la retranscription. Tout est sous
`~/Library/Application Support/VoxLocal/` (ou `VOXLOCAL_DATA_DIR`), dans le
compte macOS de l’utilisateur ([`AppPaths.swift`](../mac/VoxLocal/Sources/VoxLocal/AppPaths.swift)) :

| Chemin | Contenu |
|---|---|
| `data/history/<id>/audio.wav` et `record.json` | audio de la dictée, transcription brute, texte final, mode, modèles, application cible |
| `remote-scribe/sessions/<uuid>/remote.wav` | WAV reçu de l’iPhone, conservé aussi quand l’arrêt est refusé pour permettre une nouvelle tentative |
| `data/settings.json` | réglages, sans aucun jeton |
| `remote-scribe/tls/` | certificat et clé privée du poste (dossier `0700`, clé `0600`) |
| `models/` | modèles Whisper et LLM |
| `run/llama-server.pid` | PID du serveur LLM local, pour l’arrêter après un plantage |

La version 2.3.0 n’a ni durée de rétention réglable ni suppression depuis
l’interface : l’effacement se fait en supprimant ces dossiers (Réglages ›
Général › Données locales › « Ouvrir le dossier »). La confidentialité de ces
fichiers repose sur le chiffrement du disque (FileVault) et sur le compte
macOS. Une politique de rétention est une porte de pilote.

**iPhone.** L’historique est en mémoire seulement par défaut et disparaît à la
fermeture de l’app. L’utilisateur peut activer « Conserver l’historique sur cet
appareil » : il est alors rangé dans un élément du trousseau lié à cet
appareil (`ThisDeviceOnly`), qui ne se restaure pas sur un autre appareil. Désactiver l’option ou
effacer l’historique pose d’abord une marque de purge, pour qu’un effacement
incomplet ne recharge pas d’ancien texte. « Copier » place le texte dans le
presse-papier local uniquement (pas de Handoff) avec une expiration de 2 minutes
([`ContentView.swift`](../ios/RemoteScribePortable/ContentView.swift),
[`ios-stability.md`](ios-stability.md)).

**Pod GPU (option).** Les journaux et le jeton du Pod vivent sur son volume
persistant `/workspace` ; il faut vérifier sur le Pod réel qu’aucun audio ni
texte n’y reste, puis supprimer le Pod et le volume en fin d’usage (voir
`docs/cloud-deployment.md`).

## Secrets

Principe commun : un secret n’apparaît jamais dans les arguments d’un processus
(visibles par `ps` pour tous les comptes), ni dans un fichier suivi par git, ni
dans un journal ou un message d’erreur.

| Secret | Où il vit | Fichier |
|---|---|---|
| Code d’appairage, Mac | trousseau macOS ; si l’écriture d’un code régénéré échoue, l’ancien est supprimé du trousseau pour qu’un code révoqué ne revienne pas au lancement suivant | [`PlatformServices.swift`](../mac/VoxLocal/Sources/VoxLocal/PlatformServices.swift), [`RemoteScribeIntegration.swift`](../mac/VoxLocal/Sources/VoxLocal/RemoteScribeIntegration.swift) |
| Jeton GPU cloud, Mac | trousseau macOS, jamais dans `settings.json` | [`PlatformServices.swift`](../mac/VoxLocal/Sources/VoxLocal/PlatformServices.swift) |
| Clé de `llama-server` | aléatoire à chaque démarrage, passée par la variable `LLAMA_API_KEY`, jamais en argument | [`LLMServer.swift`](../mac/VoxLocal/Sources/VoxLocal/LLMServer.swift) |
| Clé privée TLS du poste | fichier `0600` dans un dossier `0700` (Mac, macOS/Linux) ; ACL limitée au compte d’installation sous Windows, resserrée à chaque réutilisation | [`TLSIdentity.swift`](../RemoteScribe/Core/Sources/TLSIdentity.swift), [`new-tls-identity.ps1`](../windows/new-tls-identity.ps1) |
| Code d’appairage et empreintes, iPhone | trousseau iOS, `ThisDeviceOnly` ; si le trousseau refuse, conservés en mémoire pour la session et l’app le signale | [`SecurePairingStore.swift`](../ios/RemoteScribePortable/SecurePairingStore.swift) |
| Hôte CLI Swift `RemoteScribeHost` | en TLS, le code vient de `--pairing-code-file` (fichier `0600` exigé) ou de `REMOTESCRIBE_PAIRING_CODE` ; `--pairing-code` en argument n’est accepté qu’avec `--insecure-plaintext` | [`main.swift`](../RemoteScribe/MacServer/Sources/main.swift) |
| Hôte Python, API agent, Windows | variables d’environnement du service : `VOXLOCAL_PAIRING_CODE`, `VOXLOCAL_GPU_TOKEN`, `VOXLOCAL_LLM_TOKEN`, `VOXLOCAL_AGENT_TOKEN` ; les lanceurs Windows et le CLI agent refusent les secrets en argument | [`server/run-windows.ps1`](../server/run-windows.ps1), [`agent/run-windows.ps1`](../agent/run-windows.ps1), [`voxlocal_agent_api.py`](../agent/voxlocal_agent_api.py) |
| Jeton du Pod GPU | secret RunPod écrit dans `/workspace/voxlocal/api-token` (`600`) ; jamais affiché, jamais copié sur le poste par les scripts | [`cloud/runpod/start-all.sh`](../cloud/runpod/start-all.sh), `docs/cloud-deployment.md` |

L’hôte Python accepte encore `--pairing-code` en argument pour compatibilité ;
les procédures de ce dépôt utilisent toujours `VOXLOCAL_PAIRING_CODE`. Sous
Windows, la tâche planifiée de démonstration lit les secrets dans
l’environnement du compte ; pour un pilote, injectez-les depuis le coffre de
l’hôpital (Credential Manager, DPAPI) avec un compte de service dédié
([`windows-deployment.md`](windows-deployment.md)).

Le [`.gitignore`](../.gitignore) exclut `*.pem`, `*.key`, `*.p12`, `*.crt`,
`.env`, `api-token` et `runtime.env`. Les tests n’utilisent que de l’audio
synthétique (silence ou tonalité) et des phrases cliniques fictives.

## Journalisation

Règle : les journaux notent des événements, des états et des tailles, jamais le
texte dicté, jamais l’audio.

- **Hôte Python.** Événements `server_ready`, `client_paired`,
  `session_started`, `session_completed bytes=<n>`, `inference_failed type=<classe>`,
  `server_stopped`. L’empreinte du certificat figure dans `server_ready` : elle
  est publique et sert à la vérification. Les erreurs de démarrage décrivent la
  configuration, jamais une requête ([`voxlocal_server.py`](../server/voxlocal_server.py)).
- **API agent.** Chaque réponse porte un `requestId` transmis au moteur en
  `X-Request-ID`, pour corréler un incident sans contenu clinique. Les erreurs ne
  reprennent ni le corps de la réponse du fournisseur, ni l’URL complète, ni un
  secret ([`agent-api.md`](agent-api.md)).
- **VoxLocal sur Mac.** L’app ne tient pas de journal applicatif en 2.3.0 : le
  dossier `logs/` est créé mais aucun code n’y écrit. Les événements du serveur
  Remote Scribe (connexion d’un appareil, port, erreurs) s’affichent dans
  l’interface. `llama-server` est lancé avec `--log-disable` et `whisper-cli`
  avec `-np`. Le texte des dictées se trouve dans l’historique décrit plus haut,
  pas dans un journal. Les erreurs du GPU cloud n’affichent que le code HTTP,
  jamais le corps renvoyé par le fournisseur
  ([`CloudGPU.swift`](../mac/VoxLocal/Sources/VoxLocal/CloudGPU.swift)).
- **Pod GPU.** D’après la conception livrée (voir `docs/cloud-deployment.md`),
  la porte HTTPS n’a pas de journal d’accès ; Whisper journalise la durée, la
  langue et le nom du fichier envoyé (`audio.wav`), jamais le texte.

**Limite.** Il n’existe pas encore de journal d’audit « qui a dicté quoi, depuis
quel appareil, quand ». Si votre établissement l’exige, il faut le définir avec
le DPO : un tel journal contiendrait lui-même des données personnelles.

## Fournisseur GPU

Le GPU privé est optionnel : le parcours par défaut n’en a pas besoin. Il sert
aux modèles trop gros pour le poste.

**Ce que le code impose déjà.**

- HTTPS obligatoire vers un endpoint distant ; HTTP n’est accepté que vers
  `localhost` ([`CloudGPU.swift`](../mac/VoxLocal/Sources/VoxLocal/CloudGPU.swift),
  [`voxlocal_server.py`](../server/voxlocal_server.py), [`voxlocal_agent_api.py`](../agent/voxlocal_agent_api.py)).
- Jeton obligatoire, distinct par capacité (voix, nettoyage, LLM) si vous le
  souhaitez ; pas d’identifiants, de query ni de fragment dans l’URL.
- Requêtes LLM avec `store: false` ; en-têtes `Cache-Control: no-store` et
  `X-Remote-Scribe-ZDR: required`. Cet en-tête est un signal : il ne prouve
  rien sur le comportement du fournisseur.
- Pas de redirection suivie, pas de proxy hérité de l’environnement, réponses
  plafonnées (4 Mio sur Mac), CA privée possible (`--gpu-ca-file`).

**La conception RunPod livrée.** Un Pod privé fait tourner `whisper-server` et
`llama-server` sur `127.0.0.1`, derrière une seule porte HTTPS en TLS 1.3 qui
exige le jeton Bearer. Aucun endpoint, modèle, région ou engagement ZDR n’est
écrit dans le dépôt ([`cloud/runpod/README.md`](../cloud/runpod/README.md),
[`agent-runtime-plan.md`](agent-runtime-plan.md), [`runpod-runtime.md`](runpod-runtime.md)).
Le déploiement en une commande, le certificat du Pod et la grille de coûts sont
décrits dans `docs/cloud-deployment.md`. **Aucun Pod n’a encore été
provisionné** : aucune mesure GPU réelle n’existe à ce jour.

**Ce que le fournisseur doit prouver avant toute donnée patient.**

1. Un DPA signé, avec la liste des sous-traitants.
2. Zéro rétention : ni stockage, ni journalisation du contenu, ni entraînement.
3. La région et le centre de données (Secure Cloud), compatibles avec votre
   politique d’hébergement de données de santé.
4. Les journaux, instantanés et volumes : ce qui est conservé, combien de
   temps, et comment le supprimer.
5. L’image déployée (digest), les versions de modèles et de CUDA.
6. La rotation du jeton et l’arrêt ou la suppression du Pod et du volume en fin
   d’usage.

Un fournisseur qui ne répond pas sur un de ces points doit être traité comme un
échec de déploiement.

### Ce que votre DPO et votre RSSI doivent encore valider

- **Identité des appareils** : mTLS ou enrôlement MDM, rotation et révocation
  individuelle ; le code d’appairage seul ne suffit pas pour un pilote élargi.
- **Rétention sur le Mac** : durée de conservation de l’historique VoxLocal et
  procédure de suppression, avec FileVault activé sur chaque poste.
- **Fournisseur GPU**, si utilisé : les six points ci-dessus.
- **Déploiement du poste** : paquet Windows validé sur un poste réel du parc,
  service Windows signé avec coffre de secrets ; signature Developer ID et
  notarisation du DMG macOS ; signature de distribution de l’app iOS.
- **Analyse d’impact (AIPD)**, registre des traitements et information des
  patients.
- **Validation clinique** : relecture humaine des textes réécrits avant usage,
  procédure d’incident, test de suppression.
- **Journal d’audit**, si votre établissement l’exige.

L’état de chaque porte est suivi dans [`release-readiness.md`](release-readiness.md).
