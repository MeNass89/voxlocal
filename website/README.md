# Vitrine VoxLocal

Page produit publique de VoxLocal : dictée clinique locale sur le poste, avec
l’iPhone comme microphone (Remote Scribe).

Sections : accueil, « Le produit aujourd’hui » (captures réelles), « Comment ça
marche », « Sécurité » (six garanties, chacune liée au livre blanc
`docs/security-whitepaper.md`), « Déploiement » (Mac, poste Windows, GPU privé),
« Tarifs » (offre de pilote hospitalier, sans prix public) et contact.

L’adresse `contact@voxlocal.ai` reste provisoire avant une publication officielle.

## Captures d’écran

Les captures sont servies depuis `public/screenshots/` sous des noms stables
(`mac-main`, `ios-home`), chacune en PNG (repli) et en WebP (servi en priorité).
Pour remplacer une capture, écraser le PNG puis régénérer le WebP :

```bash
sips -Z 1600 public/screenshots/mac-main.png   # iPhone : -Z 1400
cwebp -q 82 -m 6 public/screenshots/mac-main.png -o public/screenshots/mac-main.webp
```

Mettre à jour `width`/`height` dans `app/components/ProductShots.tsx` si le
ratio change (`sips -g pixelWidth -g pixelHeight <fichier>`).

## Prévisualisation

```bash
pnpm install
pnpm run dev
```

## Vérification

```bash
pnpm test        # build + rendu HTML : sections, images dimensionnées, aucun prix inventé
pnpm run lint
```

Poids de la page d’accueil (budget : 600 kB transférés) :

```bash
B=http://127.0.0.1:3000; t=$(curl -s -o /dev/null -w '%{size_download}' $B/)
for a in $(curl -s $B/ | grep -oE '(src|href|srcSet)="/[^"#]*"' | sed -E 's/^[a-zA-Z]+="//; s/"$//' | grep -v '\.png$' | sort -u); do
  t=$((t + $(curl -s -o /dev/null -w '%{size_download}' $B$a))); done; echo "$t octets"
```
