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
  --tls-cert C:\VoxLocal\certs\server.pem `
  --tls-key C:\VoxLocal\certs\server-key.pem `
  --llm-url https://gpu-interne.example `
  --whisper-model large-v3
```

Le binaire macOS indique `/v1/audio/transcriptions`, `/v1/chat/completions` et
`/v1/models`. Le serveur construit le WAV en mémoire, envoie l’en-tête
`X-Remote-Scribe-ZDR: required`, limite les réponses et refuse les redirections.
L’engagement ZDR, la région, les journaux du fournisseur et le DPA doivent être
vérifiés séparément : un header ne constitue pas une preuve de conformité.

`--tls-client-ca` active la demande d’un certificat client mTLS. Sans cette
option, TLS protège le transport mais l’appairage reste le contrôle applicatif.
Le pinning côté iOS, l’enrôlement/révocation d’appareils et la validation DPO
sont des critères du pilote avant toute donnée patient.

## Pare-feu et découverte

Lier `--host` à l’interface clinique explicite, puis appliquer
[install-firewall-rule.ps1](../windows/install-firewall-rule.ps1) avec les CIDR
des appareils autorisés. La règle est Private uniquement ; ne pas exposer le
port à Internet ou au profil Public. Bonjour est facultatif (`pip install -r
server/requirements-windows.txt`) et n’est jamais une preuve d’identité.

`server/run-windows.ps1` démarre l’hôte en conservant les secrets dans les
variables d’environnement. Ce script doit être adapté au certificat, au compte
de service et au coffre de secrets de l’hôpital avant installation.
