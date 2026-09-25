# Design system

## Scene
Un soignant consulte rapidement l’écran d’un iPhone dans un couloir ou une salle de soins bruyante, puis verrouille parfois l’écran pendant une dictée. L’écran doit rester sobre, contrasté et lisible en lumière forte comme en mode sombre.

## Direction
Produit natif iOS, sombre par défaut pour limiter l’éblouissement. Neutres bleutés très peu chromatiques, une seule couleur d’action violette, vert réservé à l’état prêt/terminé, rouge uniquement pour arrêter ou signaler une erreur. Les surfaces utilisent des séparations fines et des espaces généreux plutôt que des ornements.

## Tokens
- Fond: `Color(red: 0.035, green: 0.045, blue: 0.075)`
- Surface: blanc à 7–10 % d’opacité
- Texte principal: blanc à 96 %
- Texte secondaire: blanc à 68 %
- Action: indigo `#635BFF`
- Prêt: vert `#34C759`
- Alerte: orange `#FF9F0A`
- Erreur/arrêt: rouge `#FF453A`
- Rayon principal: 20–28 pt, style continuous
- Cibles tactiles: au moins 44 pt, bouton de dictée 64 pt

## Typography and accessibility
Utiliser les styles Dynamic Type natifs. Les informations d’état combinent symbole, titre et explication. Ne jamais encoder un état par la seule couleur. Les libellés et VoiceOver doivent annoncer l’action et sa conséquence.

## Liquid Glass (préférence utilisateur, 24 septembre 2026)

Privilégier les composants iOS natifs : `.glassProminent` pour dicter/arrêter,
`.glass` pour connexion, reprise, partage, texte brut/final et effacement.
Laisser navigation, feuilles, Picker, Form et Toggle adopter le rendu du système,
sans fond de barre opaque ni verre superposé. Garder le texte médical sur une
surface de contenu contrastée. Les groupes de boutons voisins passent par
`GlassEffectContainer`; les actions de résultat s’empilent si la largeur ou
Dynamic Type l’exige. Sous iOS 26, utiliser les styles `.bordered` et
`.borderedProminent`. Respecter Reduce Motion pour les animations custom.
