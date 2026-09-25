# Codec et hôte de compatibilité Windows

`remotescribe_protocol.py` est le codec v1 strict (trames big-endian,
UUID/session, séquences, fragmentation TCP, PCM S16LE 16 kHz). `remotescribe_host.py`
est un hôte minimal utile pour une intégration synthétique ou un test de
transport ; il reste en TCP clair et ne doit pas recevoir de données cliniques.

Pour le serveur de référence avec TLS, quotas, limites d’inférence, appairage,
Bonjour optionnel et backend GPU HTTPS, utilisez [`server/voxlocal_server.py`](../server/README.md).

Tests :

```powershell
py -3.11 -m unittest discover -s windows -p "test_*.py" -v
```

Le petit hôte accepte un GPU HTTPS via `REMOTESCRIBE_GPU_URL` et
`REMOTESCRIBE_GPU_TOKEN`, ajoute `X-Remote-Scribe-ZDR: required` et n’écrit pas
d’audio. Ce header ne remplace pas un DPA fournisseur ni TLS côté téléphone.

Le pare-feu de pilote se configure avec
[install-firewall-rule.ps1](install-firewall-rule.ps1), en limitant
`-RemoteAddress` au VLAN clinique et au profil Private.

## Installation Windows

Le runtime local et sa désinstallation réversible sont documentés dans [docs/windows-deployment.md](../docs/windows-deployment.md). Utilisez [install-runtime.ps1](install-runtime.ps1) pour créer la venv et installer le paquet local, puis [uninstall-runtime.ps1](uninstall-runtime.ps1) pour retirer le manifeste et une éventuelle tâche planifiée. Les lanceurs restent des processus Python au premier plan : une tâche planifiée au login est optionnelle et n'est pas présentée comme un Windows Service.
