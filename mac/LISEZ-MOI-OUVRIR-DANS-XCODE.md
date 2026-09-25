# VoxLocal — code source complet

Cette archive contient le code source, et pas seulement l'application macOS
compilée.

## Structure à conserver

Les deux dossiers doivent rester côte à côte :

```text
VoxLocal-Source-Complet/
├── VoxLocal/
└── RemoteScribe/
```

`VoxLocal/Package.swift` référence `../RemoteScribe`. Déplacer uniquement le
dossier `VoxLocal` casserait donc la dépendance.

## Ouvrir dans Xcode

VoxLocal est un Swift Package et non un projet `.xcodeproj` classique.

1. Ouvrir Xcode.
2. Choisir **File > Open**.
3. Sélectionner le dossier `VoxLocal` ou le fichier
   `VoxLocal/Package.swift`.
4. Sélectionner le schéma **VoxLocal**.

En ligne de commande :

```bash
open -a Xcode VoxLocal/Package.swift
```

## Construire l'application macOS complète

Depuis la racine de cette archive :

```bash
cd VoxLocal
./setup.sh
./build.sh
open dist/VoxLocal.app
```

Les exécutables `whisper-cli` et `llama-cli` déjà fournis dans `Vendor/bin`
sont compilés pour Mac Intel (`x86_64`). Sur un Mac Apple Silicon, ils peuvent
fonctionner via Rosetta ; pour les reconstruire nativement, installer CMake
puis lancer :

```bash
cd VoxLocal
./build-runtimes.sh
./build.sh
```

## Contenu

- `VoxLocal/Sources/VoxLocal/` : code Swift/SwiftUI principal ;
- `RemoteScribe/Core/Sources/` : bibliothèque Swift requise par VoxLocal ;
- `VoxLocal/Vendor/src/` : sources de whisper.cpp et llama.cpp ;
- `VoxLocal/Vendor/bin/` : runtimes déjà compilés ;
- `VoxLocal/assets/` et `VoxLocal/App/` : icônes et métadonnées du bundle ;
- `VoxLocal/Website/` : site du projet ;
- `RemoteScribe/PortableClient/` : client iOS et son projet Xcode.

Les caches et produits générés (`.build`, `dist`, dossiers CMake temporaires)
ont volontairement été retirés : ils ne sont pas du code source et sont
recréés lors de la compilation.

Les modèles Whisper/GGUF ne sont pas inclus. Ce sont des poids de modèles
volumineux installés séparément, pas le code source de l'application.
