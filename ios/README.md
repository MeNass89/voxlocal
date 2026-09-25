# Remote Scribe Portable

Client natif SwiftUI pour iPhone et iPad. Il utilise le protocole TCP/TLS
`RemoteScribeCore` avec `PAIR`, `START_SESSION`, `AUDIO_CHUNK`, `STOP_SESSION`
et `SESSION_STATUS`.

## Installer

1. Ouvrir `RemoteScribePortable.xcodeproj` dans Xcode.
2. Choisir une Team Apple dans **Signing & Capabilities**.
3. Brancher l’iPhone ou l’iPad, sélectionner l’appareil et cliquer Run.
4. Autoriser le réseau local et le microphone au premier lancement.

La cible déclare le mode d’arrière-plan `audio` pour une dictée déjà démarrée.
Le code d’appairage est obligatoire et est conservé dans le Keychain
`ThisDeviceOnly` si le trousseau est disponible. Le TLS est activé par défaut
pour les nouvelles installations ; le mode TCP brut est réservé au test
synthétique sur VLAN/tunnel contrôlé.

L’app détecte `_remotescribe._tcp` avec Bonjour, mais n’ouvre jamais
automatiquement un serveur découvert. Sélectionnez un poste explicitement, ou
saisissez son nom/adresse IP et le port `47365`.

## Historique local

Les transcriptions restent en mémoire par défaut et disparaissent à la
fermeture de l’app. L’option « conserver l’historique » est volontaire ; les
résultats sont alors stockés dans le Keychain appareil uniquement et peuvent
être effacés depuis l’interface.

## Serveur de test

Depuis la racine du dépôt, pour des données synthétiques uniquement :

```bash
export VOXLOCAL_PAIRING_CODE=test-only-123456
python3 server/voxlocal_server.py --mock --insecure-test-only --host 127.0.0.1 --pairing-code test-only-123456
```

Pour le serveur Windows/TLS et le GPU privé, voir [`server/README.md`](../../server/README.md)
et [`windows/README.md`](../../windows/README.md). Pour le mock TCP local, désactivez TLS dans le panneau de connexion ; ce profil ne doit recevoir aucune donnée clinique.
