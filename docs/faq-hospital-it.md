# FAQ pour l’équipe informatique de l’hôpital

Réponses courtes, à jour au 25 septembre 2026 (VoxLocal.app 2.3.0, Remote Scribe
iOS 1.3). Le détail de chaque mécanisme de sécurité est dans le
[livre blanc sécurité](security-whitepaper.md).

### 1. Quels ports et protocoles faut-il ouvrir ?

Un seul port entrant sur le poste : **TCP 47365**, en TLS 1.3, depuis le VLAN où
se trouvent les iPhones. Aucun port entrant sur l’iPhone. Sous Windows,
[`install-firewall-rule.ps1`](../windows/install-firewall-rule.ps1) crée une règle
limitée au profil Private et à la plage d’adresses que vous indiquez
(`-RemoteAddress`). Le serveur LLM local du Mac et l’API agent (`47366`)
n’écoutent que sur `127.0.0.1`. En sortie, rien, sauf si vous activez un GPU
privé (HTTPS vers l’adresse que vous configurez).

### 2. Faut-il Bonjour (mDNS) ?

Non, mais c’est plus simple. Le Mac publie `_remotescribe._tcp` avec l’empreinte
du certificat. L’hôte Python ne publie Bonjour que si le paquet `zeroconf` est
installé et qu’il écoute sur une adresse précise ; sinon l’utilisateur saisit
l’adresse du poste. Bonjour ne sert qu’à trouver un candidat : l’iPhone ne s’y
connecte pas sans code d’appairage et vérification de l’empreinte. Si votre
Wi-Fi isole les clients ou filtre le multicast, utilisez le QR code ou l’adresse
manuelle.

### 3. Quels certificats ? Peut-on utiliser notre CA ?

Par défaut, chaque poste crée un certificat RSA 2048 auto-signé valable 10 ans,
et l’iPhone épingle son empreinte (SHA-256 du certificat DER) à la première
connexion ou via le QR code. Vous pouvez fournir un certificat émis par votre CA
(`--tls-cert` / `--tls-key`, ou `-TlsCert` / `-TlsKey` sous Windows). Si le
profil de votre CA est installé sur les iPhones par MDM, la première connexion
est acceptée sans confirmation et la CA garde la main sur la rotation. Détails :
[Transport](security-whitepaper.md#transport).

### 4. Que se passe-t-il si le certificat du poste change ?

L’iPhone refuse la connexion (« L’identité du poste a changé. Vérifiez-le avant
de réessayer. ») avant d’envoyer le moindre octet audio. Après un changement
légitime, l’utilisateur choisit « Oublier ce poste » puis vérifie la nouvelle
empreinte sur l’écran du poste. Un QR code ne remplace jamais une empreinte déjà
épinglée. Sous Windows, gardez le dossier TLS hors de `-InstallRoot` si vous
voulez que l’empreinte survive à une réinstallation : `uninstall-runtime.ps1`
supprime une identité placée sous `-InstallRoot`.

### 5. Comment contrôler quels appareils se connectent ? Et le MDM ?

Aujourd’hui : un code d’appairage par poste, transmis dans la connexion TLS. 5
codes erronés depuis une même adresse bloquent cette adresse pendant 60 s. Le
code peut être régénéré à tout moment sur le Mac, ce qui déconnecte tous les
appareils. Il n’y a pas encore d’identité par appareil : le certificat client
(mTLS), l’enrôlement et la révocation individuelle sont à construire avec votre
MDM et votre CA. L’app iOS se distribue par MDM une fois signée avec le compte
Apple Developer de l’hôpital.

### 6. Quel matériel faut-il ?

- **Mac** : Apple Silicon, **macOS 15 ou plus récent** (exigé pour que la clé TLS
  ne soit pas importée dans le trousseau de session). 16 Go de mémoire recommandés
  avec les modèles conseillés. Le Mac de mesure est un M2 16 Go.
- **iPhone / iPad** : iOS 16 ou plus récent ; l’interface Liquid Glass s’active
  sur iOS 26 et plus.
- **Windows** : Windows 10/11 x64, PowerShell 5.1 ou plus récent, Python 3.11 ou
  plus récent déjà installé.

### 7. Quelle taille font les modèles ?

Modèles recommandés sur Mac : Whisper `ggml-large-v3-turbo-q5_0.bin` (574 MB)
et `qwen2.5-3b-instruct-q4_k_m.gguf` (2,1 GB). VoxLocal propose de les
télécharger depuis Hugging Face et refuse un fichier dont le SHA-256 diffère de
celui inscrit dans l’app ([`ModelCatalog.swift`](../mac/VoxLocal/Sources/VoxLocal/ModelCatalog.swift)) ;
vous pouvez aussi déposer vos propres fichiers dans le dossier des modèles. Les
performances publiées ([`mac-performance.md`](mac-performance.md)) ont été
mesurées avec les plus petits modèles (tiny et 0.5B) ; les modèles recommandés
restent à mesurer.

### 8. Est-ce que ça marche hors ligne ?

Sur Mac, oui : Whisper et le LLM tournent sur le poste, et l’iPhone parle au poste
sur le réseau local. Seul le téléchargement initial des modèles demande
Internet ; vous pouvez le faire vous-même et copier les fichiers. Le mode GPU
privé et l’hôte Python réel ont besoin de joindre leur endpoint GPU.

### 9. Et sous Windows ?

L’hôte Python fonctionne sous Windows, mais en 2.3.0 il ne transcrit pas
lui-même : il appelle un endpoint compatible OpenAI (votre serveur Whisper
interne ou le GPU privé), ou tourne en mock synthétique. L’installateur
([`windows-deployment.md`](windows-deployment.md)) copie le runtime dans
`C:\ProgramData\VoxLocal`, crée un environnement virtuel sans téléchargement,
génère l’identité TLS et peut créer une **tâche planifiée** au login. Ce n’est
pas encore un service Windows : pour un pilote, prévoyez un compte de service,
un coffre de secrets (Credential Manager ou DPAPI) et un wrapper signé.
L’installateur et la désinstallation sont exécutés en CI sur `windows-latest`,
pas encore sur un poste de votre parc.

### 10. Où sont stockées les données ?

Sur l’iPhone : en mémoire par défaut, dans le trousseau de l’appareil si
l’utilisateur active la conservation. Sur l’hôte Python : nulle part, l’audio
reste en mémoire. Sur le Mac : VoxLocal garde un historique (audio WAV et
textes) dans `~/Library/Application Support/VoxLocal/`, dans le compte de
l’utilisateur, sans durée de rétention automatique en 2.3.0. Activez FileVault
et définissez une politique de purge. Détails :
[Données au repos](security-whitepaper.md#données-au-repos).

### 11. Où sont les secrets ?

Trousseau macOS et iOS pour le code d’appairage, le jeton GPU et les empreintes
épinglées ; variables d’environnement du service sous Windows et pour l’hôte
Python. Jamais en argument de processus, jamais dans un fichier de réglages,
jamais dans git. Voir [Secrets](security-whitepaper.md#secrets).

### 12. Y a-t-il des journaux d’audit ?

Les journaux techniques notent des événements (appairage, début et fin de
session, tailles en octets, erreurs) et jamais le texte ni l’audio. Il n’y a pas
encore de journal d’audit nominatif « qui a dicté quoi, quand ». S’il vous en
faut un, définissez-le avec votre DPO : il contiendrait lui-même des données
personnelles. Voir [Journalisation](security-whitepaper.md#journalisation).

### 13. Comment se font les mises à jour ?

Il n’y a pas de mise à jour automatique. Le DMG macOS se reconstruit depuis le
dépôt (`./scripts/build-macos.sh`) ; il est signé ad hoc, pas encore notarisé, et
se déploie par votre outil de gestion du parc une fois signé Developer ID.
L’app iOS passe par Xcode aujourd’hui, par MDM ou TestFlight après signature de
distribution. Sous Windows, relancez l’installateur ; il réutilise l’identité TLS
existante, donc les iPhones n’ont rien à refaire.

### 14. Quelles langues ?

Whisper est multilingue. VoxLocal propose français, anglais, espagnol et
allemand, ou la détection automatique. L’interface des apps et les invites des
modes fournis sont en français. La qualité de la transcription dépend du modèle
Whisper choisi ; elle n’a pas été validée cliniquement.

### 15. Peut-on utiliser un GPU loué ? À quelles conditions ?

Oui, en option. Le poste envoie alors l’audio et le texte en HTTPS avec jeton à un
endpoint compatible OpenAI. La conception RunPod livrée place Whisper et le LLM
derrière une seule porte HTTPS authentifiée (voir `docs/cloud-deployment.md`) ;
aucun Pod n’a encore été provisionné. Avant toute donnée patient, le fournisseur
doit fournir un DPA, un engagement de zéro rétention, la région de traitement et
la politique de journaux. Voir [Fournisseur GPU](security-whitepaper.md#fournisseur-gpu).

### 16. Qu’est-ce qui manque avant un pilote avec des patients réels ?

La signature Apple (distribution iOS, Developer ID et notarisation macOS),
l’enrôlement des appareils (mTLS par MDM), la politique de rétention sur le Mac,
le contrat GPU si l’option est retenue, la validation DPO et la validation
clinique, et un essai Windows sur un poste réel. Liste suivie dans
[`release-readiness.md`](release-readiness.md).
