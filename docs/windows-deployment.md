# Déploiement Windows du runtime VoxLocal

Ce chemin installe le runtime Python local dans `C:\ProgramData\VoxLocal`, crée
un environnement virtuel sans téléchargement réseau et peut enregistrer un
Scheduled Task de session. Le script ne transforme pas le prototype en service
Windows : pour un pilote clinique, l’équipe IT doit fournir un compte de service,
un coffre de secrets (Credential Manager/DPAPI ou équivalent) et un wrapper signé.

## Pré-requis

- Windows 10/11 x64, PowerShell 5.1 ou plus récent ;
- Python 3.11+ déjà installé et accessible par `python`, `python3` ou `py -3.11` ;
- droits administrateur pour le chemin ProgramData, les tâches et le pare-feu ;
- certificat serveur, clé privée et, si retenu, CA client gérée par l’hôpital ;
- un poste et un VLAN clinique documentés. Le mode mock ne sert qu’aux données
  synthétiques et reste sur loopback.

## Installer depuis une copie du dépôt

Depuis PowerShell élevé, dans la racine du dépôt :

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\install-runtime.ps1 -InstallRoot C:\ProgramData\VoxLocal
```

Le script copie seulement `agent`, `server`, `windows` et `pyproject.toml`, crée
`.venv`, installe le package avec `pip --no-index` et écrit un manifeste de
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

Pour un serveur réel, fournir une interface clinique explicite et TLS :

```powershell
.\windows\install-runtime.ps1 `
  -RegisterScheduledTask -ScheduledTask Server `
  -BindAddress 10.42.5.20 `
  -TlsCert C:\VoxLocal\certs\server.pem `
  -TlsKey C:\VoxLocal\certs\server-key.pem `
  -TlsClientCA C:\VoxLocal\certs\hospital-client-ca.pem `
  -GpuCAFile C:\VoxLocal\certs\runpod-ca.pem
```

Le script refuse wildcard/loopback en production et refuse une tâche serveur sans
certificat. `-GpuCAFile` permet de fournir la CA privée du gateway GPU lorsque
le trust store Windows standard ne suffit pas. Configure ensuite les variables `VOXLOCAL_PAIRING_CODE`,
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
`-KeepData` si un export contrôlé est nécessaire avant suppression.

## Limites de la version actuelle

Le runtime Windows est prêt pour une démonstration et un harnais d’intégration.
La mise en service clinique demande encore la signature du code, l’identité
mTLS/pinning et l’enrôlement/révocation des appareils, le stockage des secrets
par l’IT, le DPA/ZDR du fournisseur GPU et une validation DPO/clinique. Le hôte
`windows/remotescribe_host.py` reste un compatibiliteur TCP pour données
synthétiques ; `server/voxlocal_server.py` est le chemin de référence TLS.
