# Hôte Remote Scribe Windows / VoxLocal

`server/voxlocal_server.py` est l’hôte de référence. Il reprend la trame v1
reconstruite de l’app macOS, fonctionne avec Python 3.11+ sur Windows, et ne
conserve pas d’audio ni de texte localement par défaut. Le mode `windows/` reste
un codec et un petit hôte de compatibilité pour les tests ; il n’est pas le
chemin de déploiement GPU.

## Test synthétique local

Le mode mock est explicitement marqué comme non clinique et doit rester lié à
localhost :

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
$env:VOXLOCAL_PAIRING_CODE = "test-only-123456"
py server\voxlocal_server.py --mock --insecure-test-only --host 127.0.0.1 --pairing-code test-only-123456
```

Le serveur renvoie une réponse de contrôle et n’appelle aucun modèle. Le code
d’appairage reste obligatoire, même pour ce test.

## Identité TLS de l’hôte

Le serveur refuse de démarrer sans TLS hors mode mock. Générez une fois
l’identité de l’hôte (RSA 2048 auto-signé, 10 ans, SAN `<hôte>.local`,
`localhost`, `127.0.0.1`, comme VoxLocal.app) :

```bash
# macOS / Linux : dossier en 0700, clé en 0600 ; sans --force, une identité existante est conservée
scripts/make-tls-identity.sh ~/.voxlocal/tls
```

```powershell
# Windows : openssl.exe du PATH, de Git for Windows ou de $env:OPENSSL_EXE ;
# la clé n’est lisible que par le compte courant
.\windows\new-tls-identity.ps1 -OutputDir C:\ProgramData\VoxLocal\tls
```

Les deux scripts écrivent `server.cert.pem` et `server.key.pem`, puis affichent
l’empreinte SHA-256 du certificat en base64 et en hexadécimal groupé par 4. Au
démarrage, le serveur journalise la même valeur
(`server_ready … tls_fingerprint_sha256=<base64>`) et la publie dans
l’enregistrement Bonjour (`tls=1`, `fp=<base64>`). À la première connexion,
l’iPhone affiche l’empreinte : comparez-la, caractère par caractère, avec celle
du script ou du journal avant de l’approuver. Une empreinte qui change ensuite
signifie un nouveau certificat (régénéré avec `--force`/`-Force`) ou un
intermédiaire sur le réseau ; ne l’approuvez qu’après vérification sur l’hôte.

Un certificat émis par l’IT de l’hôpital reste possible : passez-le avec
`--tls-cert`/`--tls-key` ; l’empreinte publiée est celle du premier certificat
du fichier PEM.

## GPU privé compatible OpenAI

Le serveur refuse un endpoint GPU non HTTPS, un démarrage sans TLS serveur et
un secret d’appairage court. Configurez les secrets dans l’environnement :

```powershell
$env:VOXLOCAL_PAIRING_CODE = "un-secret-de-pilote-d-au-moins-12-caracteres"
$env:VOXLOCAL_GPU_TOKEN = "..."
$env:VOXLOCAL_LLM_TOKEN = "..." # seulement si l’endpoint LLM est différent
py server\voxlocal_server.py `
  --host 10.42.5.20 `
  --backend-url https://gpu-interne.example `
  --tls-cert C:\ProgramData\VoxLocal\tls\server.cert.pem `
  --tls-key C:\ProgramData\VoxLocal\tls\server.key.pem `
  --llm-url https://gpu-interne.example `
  --whisper-model large-v3
```

Le binaire macOS indique `/v1/audio/transcriptions`, `/v1/chat/completions` et
`/v1/models`. Le serveur construit le WAV en mémoire, envoie l’en-tête
`X-Remote-Scribe-ZDR: required`, limite les réponses et refuse les redirections.
L’engagement ZDR, la région, les journaux du fournisseur et le DPA doivent être
vérifiés séparément : un header ne constitue pas une preuve de conformité.

`--tls-client-ca` active la demande d’un certificat client mTLS. Sans cette
option, TLS protège le transport, l’empreinte comparée sur l’iPhone authentifie
l’hôte et l’appairage reste le contrôle applicatif. L’enrôlement/révocation
d’appareils et la validation DPO sont des critères du pilote avant toute donnée
patient.

## Pare-feu et découverte

Lier `--host` à l’interface clinique explicite, puis appliquer
[install-firewall-rule.ps1](../windows/install-firewall-rule.ps1) avec les CIDR
des appareils autorisés. La règle est Private uniquement ; ne pas exposer le
port à Internet ou au profil Public. Bonjour est facultatif (`pip install -r
server/requirements-windows.txt`) et n’est jamais une preuve d’identité.

`server/run-windows.ps1` démarre l’hôte en conservant les secrets dans les
variables d’environnement. Ce script doit être adapté au certificat, au compte
de service et au coffre de secrets de l’hôpital avant installation.
