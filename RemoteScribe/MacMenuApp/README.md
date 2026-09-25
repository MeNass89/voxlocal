# Remote Scribe Mac

Application de barre des menus qui lance automatiquement le serveur Bonjour/TCP,
sans Terminal. VoxLocal est le moteur cible et le moteur par défaut. La passerelle
SuperWhisper reste disponible uniquement lorsqu’elle est installée.

Construire le DMG :

```bash
./MacMenuApp/build-dmg.sh
```

Sur l’autre Mac, ouvrir le DMG, glisser **Remote Scribe** dans Applications,
ouvrir l’app, puis autoriser son ouverture si macOS le demande. Le code de
pairing et le nom du poste sont accessibles depuis l’icône de barre des menus.

Cette version locale est signée ad hoc. Pour une distribution externe sans
avertissement Gatekeeper, elle devra être signée avec un certificat Developer ID
et notarialisée par Apple.
