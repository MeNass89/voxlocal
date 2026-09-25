# Déploiement Windows du runtime VoxLocal

Ce chemin installe le runtime Python local dans `C:\ProgramData\VoxLocal`, crée
un environnement virtuel sans téléchargement réseau et peut enregistrer un
Scheduled Task de session. Le script ne transforme pas le prototype en service
Windows : pour un pilote clinique, l’équipe IT doit fournir un compte de service,
un coffre de secrets (Credential Manager/DPAPI ou équivalent) et un wrapper signé.

## Pré-requis

- Windows 10/11 x64, PowerShell 5.1 ou plus récent ;
- Python 3.11+ déjà installé et accessible par `python`, `python3` ou `py -3` ;
- droits administrateur pour le chemin ProgramData, les tâches et le pare-feu ;
- `openssl.exe` pour générer l’identité TLS de l’hôte : celui de Git for
  Windows (`C:\Program Files\Git\usr\bin\openssl.exe`), un `openssl` du
  `PATH` ou `$env:OPENSSL_EXE` ; ou bien un certificat serveur et sa clé fournis
  par l’IT ; et, si retenu, une CA client gérée par l’hôpital ;
- un poste et un VLAN clinique documentés. Le mode mock ne sert qu’aux données
  synthétiques et reste sur loopback.

## Installer depuis une copie du dépôt

Depuis PowerShell élevé, dans la racine du dépôt :

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install-runtime.ps1 -InstallRoot C:\ProgramData\VoxLocal
```

Le script copie seulement `agent`, `server`, `windows` et `pyproject.toml`, crée
`.venv`, rend le paquet importable par un fichier `voxlocal.pth` (aucun `pip`, aucun index, aucun backend de build) et écrit un manifeste de
suppression. Il ne télécharge pas de modèle et n’écrit aucun token.

Pour préparer une tâche d’agent de démonstration :

```powershell
$env:VOXLOCAL_AGENT_TOKEN = 'un-token-local-de-demo-d-au-moins-16-caracteres'
.\windows\install-runtime.ps1 -RegisterScheduledTask -ScheduledTask Agent -MockTask
```

La tâche lit les secrets de l’environnement du compte au lancement. Elle est
interactive et n’est pas un service Windows ; pour un pilote, injecter les
secrets avec le coffre approuvé de l’hôpital plutôt que dans le profil ou la
commande de la tâche.

Pour un serveur réel, fournir une interface clinique explicite et TLS. Avec
`-TlsDir`, l’installateur génère l’identité TLS de l’hôte dans ce dossier (RSA
2048 auto-signé, 10 ans, SAN `<hôte>.local`, `localhost`, `127.0.0.1`) par
[`new-tls-identity.ps1`](../windows/new-tls-identity.ps1), la réutilise aux
installations suivantes et ne laisse la clé lisible que par le compte courant :

```powershell
.\windows\install-runtime.ps1 `
  -RegisterScheduledTask -ScheduledTask Server `
  -BindAddress 10.42.5.20 `
  -TlsDir C:\ProgramData\VoxLocal\tls `
  -GpuCAFile C:\VoxLocal\certs\runpod-ca.pem
```

L’installateur affiche l’empreinte SHA-256 du certificat (base64 et hexadécimal
groupé par 4) et l’écrit dans le manifeste (`tlsFingerprintSha256`). Le serveur
la journalise aussi au démarrage (`tls_fingerprint_sha256=…`) et la publie dans
Bonjour (`fp`). À la première connexion, l’iPhone affiche l’empreinte du
serveur : la comparer avec celle de l’installateur avant de l’approuver. Pour
régénérer l’identité, lancer `.\windows\new-tls-identity.ps1 -OutputDir
C:\ProgramData\VoxLocal\tls -Force` ; chaque iPhone devra approuver la nouvelle
empreinte.

mTLS (après enrôlement des iPhones, non livré) : `-TlsClientCA
C:\VoxLocal\certs\hospital-client-ca.pem` rend le certificat client
obligatoire. L’application iPhone ne présente aujourd’hui aucune identité
client ; activer cette option avant l’enrôlement fait échouer la poignée de
main TLS avant la validation de l’empreinte et l’appairage.

Un certificat émis par l’IT reste possible avec `-TlsCert`/`-TlsKey` à la place
de `-TlsDir` (les deux sont exclusifs). Le script refuse wildcard/loopback en
production et refuse une tâche serveur sans `-TlsDir` ni certificat.
`-GpuCAFile` permet de fournir la CA privée du gateway GPU lorsque le trust
store Windows standard ne suffit pas. Configurez ensuite les variables `VOXLOCAL_PAIRING_CODE`,
`VOXLOCAL_GPU_URL`, `VOXLOCAL_GPU_TOKEN` et éventuellement les variables LLM dans
le coffre de secrets du compte qui exécute la tâche. Les tokens ne doivent jamais
être passés comme arguments PowerShell.

## Pare-feu et désinstallation

Limiter l’entrée au VLAN clinique connu, sur le profil Private uniquement :

```powershell
.\windows\install-firewall-rule.ps1 `
  -ProgramPath C:\ProgramData\VoxLocal\.venv\Scripts\python.exe `
  -RemoteAddress 10.42.0.0/16
```

Prévisualiser puis retirer le runtime :

```powershell
.\windows\uninstall-runtime.ps1 -InstallRoot C:\ProgramData\VoxLocal -WhatIf
.\windows\uninstall-runtime.ps1 -InstallRoot C:\ProgramData\VoxLocal
```

La désinstallation exige le manifeste créé par l’installation et refuse les
racines de disque ou un chemin qui ne correspond pas au manifeste. Utiliser
`-KeepData` si un export contrôlé est nécessaire avant suppression. Une identité
TLS générée sous `-InstallRoot` (par exemple `C:\ProgramData\VoxLocal\tls`) est
supprimée avec le runtime : une réinstallation produit une nouvelle empreinte que
chaque iPhone devra approuver.

## Limites de la version actuelle

Le runtime Windows est prêt pour une démonstration et un harnais d’intégration.
La mise en service clinique demande encore la signature du code, l’identité
client mTLS et l’enrôlement/révocation des appareils (l’épinglage du certificat
serveur par l’iPhone est livré), le stockage des secrets
par l’IT, le DPA/ZDR du fournisseur GPU et une validation DPO/clinique. Le hôte
`windows/remotescribe_host.py` reste un compatibiliteur TCP pour données
synthétiques ; `server/voxlocal_server.py` est le chemin de référence TLS.
