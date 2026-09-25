# Liquid Glass iOS

## Décision

Le client portable garde une seule action dominante, démarrer ou arrêter la
dictée. Liquid Glass est donc réservé aux contrôles qui invitent à agir :
le bouton de connexion, le bouton primaire de dictée et les actions de reprise
de partage, de changement texte brut/final ou de suppression. Les cartes qui portent le texte de transcription restent des
surfaces de contenu à contraste contrôlé. Cette séparation suit la
[documentation Apple sur l’application de Liquid Glass aux vues personnalisées](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views).

Le `Picker` segmenté, le `Form`, le `Toggle`, la barre de navigation et la
feuille de connexion sont des contrôles SwiftUI natifs. Ils reçoivent leur
apparence système automatiquement. Les envelopper dans une deuxième couche de
verre créerait une surface imbriquée et réduirait la lisibilité. Pour plusieurs
contrôles custom proches, `VoxGlassControls` utilise
[`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer),
ce qui laisse SwiftUI calculer leur composition.

## Compatibilité

`glassEffect`, `GlassButtonStyle` et `GlassProminentButtonStyle` sont
disponibles à partir d’iOS 26. Les wrappers `voxGlassButton` et
`voxGlassProminentButton` les utilisent seulement dans un bloc
`if #available(iOS 26.0, *)`. Le projet conserve donc son déploiement iOS 16,
avec les styles système `.bordered` et `.borderedProminent` sur les appareils plus anciens.
La variante régulière est utilisée pour les actions ordinaires et la variante
prominente pour le bouton de dictée, conformément aux API
[`glass`](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass)
et
[`glassProminent`](https://developer.apple.com/documentation/SwiftUI/PrimitiveButtonStyle/glassProminent).

## Accessibilité et vérification

Les labels VoiceOver existants décrivent l’état et la conséquence de chaque
action. Les cibles restent au moins 44 points, et le bouton de dictée utilise
une hauteur minimale de 44 points dans le style natif. L’animation du niveau
audio est supprimée quand Reduce Motion est activé. Les états critiques gardent
un titre, une icône et un texte ; la couleur ne porte donc pas l’information à
elle seule. Les réglages Reduce Transparency et Increase Contrast sont laissés
aux composants Apple natifs.

Vérifications du 24 septembre 2026 :

```bash
swiftc -parse-as-library -parse source/PortableClient/RemoteScribePortable/ContentView.swift
xcodebuild -quiet -project source/PortableClient/RemoteScribePortable.xcodeproj \
  -scheme RemoteScribePortable -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/voxlocal-ios-derived CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project desktop-source/VoxLocal-Source-Complet/RemoteScribe/PortableClient/RemoteScribePortable.xcodeproj \
  -scheme RemoteScribePortable -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/voxlocal-export-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Les deux builds réussissent avec Xcode 27.0 et le SDK iOS 27.0. Le runtime
Simulator iOS 27.0 a ensuite été installé et le premier iPhone simulé a démarré
jusqu’à l’écran d’accueil. Le service CoreSimulator est resté bloqué pendant la
première installation/lancement d’une app tierce ; aucune capture de l’interface
VoxLocal n’est donc présentée comme une validation visuelle. L’iPhone physique
apparié reste visible pour le déploiement signé.
