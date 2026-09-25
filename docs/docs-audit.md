# Audit de documentation

Date : 2026-09-24

## Vérifications

- Les chemins annoncés par la racine ont été comparés à `rg --files` : les
  sources canoniques sont sous `source/`, l’hôte Windows sous `windows/` et
  l’hôte multi-backend sous `server/`.
- Les commandes Python documentées (`unittest`, `py_compile`) pointent vers des
  fichiers présents dans le dépôt.
- Les liens relatifs vers `windows/README.md`, `server/README.md`, les plans de
  sécurité et le journal de protocole existent.
- Les commandes historiques `./run-superwhisper.sh`, `WebClient/run-webclient.sh`
  étaient documentées dans les deux README du client portable, mais ces scripts
  ne sont pas présents dans l’archive actuelle. Ces instructions ont été
  remplacées par la commande reproductible `python3 server/voxlocal_server.py
  --pairing-code 123456` et des liens vers les hôtes livrés.
- `PortableClient.zip` reste cité dans les documents de reconstruction comme
  artefact d’origine ; cette mention est historique et ne décrit pas un fichier
  requis pour exécuter le dépôt.

## Limites

Le build Xcode complet, la découverte Bonjour et le backend GPU nécessitent
leurs environnements respectifs (SDK Apple, réseau local et endpoint configuré)
et ne sont donc pas validés par cet audit statique.
