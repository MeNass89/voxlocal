# VoxLocal — code source complet

Ce dossier contient le code source de l'application macOS, et pas seulement
l'application compilée.

## Structure à conserver

Dans ce dépôt, les deux dossiers doivent rester à ces emplacements :

```text
<racine du dépôt>/
├── mac/VoxLocal/
└── RemoteScribe/
```

`mac/VoxLocal/Package.swift` référence `../../RemoteScribe`. Déplacer
uniquement le dossier `mac/VoxLocal` casserait donc la dépendance.

## Ouvrir dans Xcode

VoxLocal est un Swift Package et non un projet `.xcodeproj` classique.

1. Ouvrir Xcode.
2. Choisir **File > Open**.
3. Sélectionner le dossier `mac/VoxLocal` ou le fichier
   `mac/VoxLocal/Package.swift`.
4. Sélectionner le schéma **VoxLocal**.

En ligne de commande, depuis la racine du dépôt :

```bash
open -a Xcode mac/VoxLocal/Package.swift
```

## Construire l'application macOS complète

Depuis la racine du dépôt, récupérer d'abord les sources de whisper.cpp et
llama.cpp (sous-modules git). `Vendor/bin` (les exécutables `whisper-cli` et
`llama-cli`) n'est pas versionné : le construire nativement demande CMake, et
`./setup.sh` refuse de continuer tant qu'il manque.

```bash
git submodule update --init
cd mac/VoxLocal
./build-runtimes.sh
./setup.sh
./build.sh
open dist/VoxLocal.app
```

## Contenu

- `mac/VoxLocal/Sources/VoxLocal/` : code Swift/SwiftUI principal ;
- `RemoteScribe/Core/Sources/` : bibliothèque Swift requise par VoxLocal ;
- `mac/VoxLocal/Vendor/src/` : sources de whisper.cpp et llama.cpp (sous-modules) ;
- `mac/VoxLocal/Vendor/bin/` : runtimes compilés localement (non versionnés) ;
- `mac/VoxLocal/assets/` et `mac/VoxLocal/App/` : icônes et métadonnées du bundle ;
- `website/` : site du projet ;
- `ios/` : client iOS et son projet Xcode `RemoteScribePortable.xcodeproj`.

Les caches et produits générés (`.build`, `dist`, dossiers CMake temporaires)
ne sont pas versionnés : ils ne sont pas du code source et sont recréés lors
de la compilation. Voir aussi [`docs/mac-build.md`](../docs/mac-build.md).

Les modèles Whisper/GGUF ne sont pas inclus. Ce sont des poids de modèles
volumineux installés séparément, pas le code source de l'application.
