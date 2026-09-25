#!/bin/zsh
# Build every VoxLocal release artefact into dist/ and print the GitHub release body.
#
#   ./scripts/release.sh                  # local only (default)
#   ./scripts/release.sh --publish-draft  # also `gh release create --draft`
#
# Artefacts (dist/ is git-ignored):
#   VoxLocal-<mac>.dmg                         Mac app, arm64, ad hoc signature
#   RemoteScribe-<ios>-unsigned.xcarchive.zip  iOS archive to sign in Xcode
#   VoxLocal-Windows-Runtime-<mac>.zip         agent + server + windows + pyproject.toml
#   VoxLocal-Source-<mac>.zip                  `git archive HEAD` (tracked files only)
#   RELEASE-CHECKSUMS-<mac>.txt                SHA-256 of the four files above
#   RELEASE-NOTES-<mac>.md                     the printed release body
#
# Versions come from mac/VoxLocal/App/Info.plist and ios/RemoteScribePortable/Info.plist.
# Nothing leaves the machine unless --publish-draft is passed, and even then the
# GitHub release stays a draft until a human publishes it.
set -euo pipefail

ROOT=${0:A:h:h}
DIST="$ROOT/dist"
PUBLISH_DRAFT=0
for arg in "$@"; do
  case "$arg" in
    --publish-draft) PUBLISH_DRAFT=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "Argument inconnu : $arg (seul --publish-draft est accepté)"; exit 2 ;;
  esac
done

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
MAC_PLIST="$ROOT/mac/VoxLocal/App/Info.plist"
IOS_PLIST="$ROOT/ios/RemoteScribePortable/Info.plist"
MAC_VERSION=$(plist "$MAC_PLIST" CFBundleShortVersionString)
MAC_BUILD=$(plist "$MAC_PLIST" CFBundleVersion)
IOS_VERSION=$(plist "$IOS_PLIST" CFBundleShortVersionString)
IOS_BUILD=$(plist "$IOS_PLIST" CFBundleVersion)
[[ "$MAC_VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' && "$IOS_VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || {
  print -u2 "Version illisible dans les Info.plist ($MAC_VERSION / $IOS_VERSION)"; exit 2
}
TAG="v$MAC_VERSION"
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)
DIRTY=""
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]] || DIRTY=" (arbre de travail modifié : le zip source ne contient que HEAD)"

DMG_NAME="VoxLocal-$MAC_VERSION.dmg"
IOS_NAME="RemoteScribe-$IOS_VERSION-unsigned.xcarchive.zip"
WIN_NAME="VoxLocal-Windows-Runtime-$MAC_VERSION.zip"
SRC_NAME="VoxLocal-Source-$MAC_VERSION.zip"
SUMS_NAME="RELEASE-CHECKSUMS-$MAC_VERSION.txt"
NOTES_NAME="RELEASE-NOTES-$MAC_VERSION.md"
WORK="$ROOT/build/release"

step() { print "\n==> $*"; }
/bin/mkdir -p "$DIST"
/bin/rm -rf -- "$WORK"
/bin/mkdir -p "$WORK"
/bin/rm -f -- "$DIST/$DMG_NAME" "$DIST/$IOS_NAME" "$DIST/$WIN_NAME" "$DIST/$SRC_NAME" "$DIST/$SUMS_NAME" "$DIST/$NOTES_NAME"

# --- 1. Mac DMG ---------------------------------------------------------------
step "DMG macOS $MAC_VERSION ($MAC_BUILD)"
for runtime in whisper-cli llama-cli llama-server; do
  [[ -x "$ROOT/mac/VoxLocal/Vendor/bin/$runtime" ]] || {
    print -u2 "Runtime manquant : mac/VoxLocal/Vendor/bin/$runtime (lancer mac/VoxLocal/build-runtimes.sh)"; exit 3
  }
done
APP_DIR="$WORK/mac/VoxLocal.app"
VOXLOCAL_APP_DIR="$APP_DIR" \
VOXLOCAL_SWIFT_BUILD_PATH="${VOXLOCAL_SWIFT_BUILD_PATH:-/tmp/voxlocal-release-swift}" \
VOXLOCAL_DMG_STAGING_PATH="$WORK/mac/dmg-staging" \
VOXLOCAL_DMG_PATH="$DIST/$DMG_NAME" \
  "$ROOT/scripts/build-macos.sh"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
APP_ARCHS=$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/VoxLocal")
BUNDLED_VERSION=$(plist "$APP_DIR/Contents/Info.plist" CFBundleShortVersionString)
[[ "$BUNDLED_VERSION" == "$MAC_VERSION" ]] || { print -u2 "Version du bundle $BUNDLED_VERSION ≠ $MAC_VERSION"; exit 4; }
/usr/bin/hdiutil verify "$DIST/$DMG_NAME" >/dev/null
print "codesign OK, arch $APP_ARCHS, hdiutil verify OK"

# --- 2. iOS archive, unsigned ----------------------------------------------------
step "Archive iOS $IOS_VERSION ($IOS_BUILD), non signée"
xcodebuild -version >/dev/null 2>&1 || { print -u2 "Xcode complet requis pour l’archive iOS."; exit 2; }
ARCHIVE="$WORK/ios/RemoteScribe-$IOS_VERSION.xcarchive"
xcodebuild archive \
  -project "$ROOT/ios/RemoteScribePortable.xcodeproj" \
  -scheme RemoteScribePortable \
  -configuration Release \
  -destination generic/platform=iOS \
  -derivedDataPath "${VOXLOCAL_IOS_DERIVED_DATA_PATH:-/tmp/voxlocal-release-ios-dd}" \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  -quiet
IOS_APP="$ARCHIVE/Products/Applications/RemoteScribePortable.app"
[[ -d "$IOS_APP" ]] || { print -u2 "Archive iOS sans application : $IOS_APP"; exit 4; }
ARCHIVED_IOS_VERSION=$(plist "$IOS_APP/Info.plist" CFBundleShortVersionString)
[[ "$ARCHIVED_IOS_VERSION" == "$IOS_VERSION" ]] || { print -u2 "Version archivée $ARCHIVED_IOS_VERSION ≠ $IOS_VERSION"; exit 4; }
(cd "$WORK/ios" && /usr/bin/ditto -c -k --keepParent "${ARCHIVE:t}" "$DIST/$IOS_NAME")
print "archive OK : ${IOS_APP:t} $ARCHIVED_IOS_VERSION, non signée"

# --- 3. Windows runtime zip --------------------------------------------------------
# Same content as windows/install-runtime.ps1 copies: agent, server, windows,
# pyproject.toml, plus setup.py for older pip. Tracked files only, so no
# cache, token or local state can slip in.
step "Paquet Windows"
git -C "$ROOT" archive --format=zip --prefix="VoxLocal-Windows-Runtime-$MAC_VERSION/" \
  -o "$DIST/$WIN_NAME" HEAD -- agent server windows pyproject.toml setup.py

# --- 4. Source zip ----------------------------------------------------------------
step "Export source (HEAD $COMMIT)"
git -C "$ROOT" archive --format=zip --prefix="VoxLocal-Source-$MAC_VERSION/" -o "$DIST/$SRC_NAME" HEAD

for zip in "$DIST/$IOS_NAME" "$DIST/$WIN_NAME" "$DIST/$SRC_NAME"; do
  /usr/bin/unzip -tq "$zip" >/dev/null || { print -u2 "Archive corrompue : $zip"; exit 4; }
done
if /usr/bin/unzip -Z1 "$DIST/$WIN_NAME" "$DIST/$SRC_NAME" 2>/dev/null | grep -Eq '(^|/)(api-token|runtime\.env|\.env)$|\.(pem|key|p12)$'; then
  print -u2 "Un secret potentiel est présent dans une archive."; exit 4
fi
print "unzip -t OK, aucun fichier secret"

# --- 5. Checksums ------------------------------------------------------------------
step "Sommes de contrôle"
(cd "$DIST" && /usr/bin/shasum -a 256 "$DMG_NAME" "$IOS_NAME" "$WIN_NAME" "$SRC_NAME" > "$SUMS_NAME")
cat "$DIST/$SUMS_NAME"

# --- 6. Release body -----------------------------------------------------------------
sha_of() { awk -v f="$1" '$2 == f { print $1 }' "$DIST/$SUMS_NAME"; }
size_of() { /usr/bin/stat -f %z "$DIST/$1" | awk '{ if ($1 < 1048576) printf "%d ko", $1 / 1024; else printf "%.1f Mo", $1 / 1048576 }'; }
cat > "$DIST/$NOTES_NAME" <<EOF
# VoxLocal $MAC_VERSION — Remote Scribe $IOS_VERSION

Dictée clinique locale : l’iPhone sert de microphone, le Mac transcrit (whisper.cpp)
et met en forme (llama.cpp) sans envoyer la voix dans le cloud. Commit \`$COMMIT\`$DIRTY.

## Fichiers

| Fichier | Contenu | Taille | SHA-256 |
| --- | --- | --- | --- |
| \`$DMG_NAME\` | App macOS $MAC_VERSION (build $MAC_BUILD), $APP_ARCHS, signature ad hoc, runtimes whisper-cli / llama-cli / llama-server inclus | $(size_of "$DMG_NAME") | \`$(sha_of "$DMG_NAME")\` |
| \`$IOS_NAME\` | Archive Xcode de Remote Scribe $IOS_VERSION (build $IOS_BUILD), **non signée** : à signer dans Xcode (Organizer → Distribute) | $(size_of "$IOS_NAME") | \`$(sha_of "$IOS_NAME")\` |
| \`$WIN_NAME\` | Hôte Windows : \`agent/\`, \`server/\`, \`windows/\`, \`pyproject.toml\` ; installer avec \`windows/install-runtime.ps1\` | $(size_of "$WIN_NAME") | \`$(sha_of "$WIN_NAME")\` |
| \`$SRC_NAME\` | Source complète au commit \`$COMMIT\` (fichiers suivis par git) | $(size_of "$SRC_NAME") | \`$(sha_of "$SRC_NAME")\` |

Vérifier : \`shasum -a 256 -c $SUMS_NAME\`.

## Ce qui est prouvé dans le dépôt

- **Mac** : serveur LLM chaud entre deux dictées, runtimes natifs arm64 (Metal), onboarding des modèles, écran iPhone avec QR d’appairage. Mesure : \`docs/superpowers/evidence/2026-09-25-mac-bench.json\`.
- **iPhone / iPad** : premier lancement guidé, appairage par QR ou saisie avec empreinte TLS, écran de résultat, mise en page iPad. Captures du simulateur dans \`docs/superpowers/evidence/\`.
- **Cloud privé (RunPod)** : image CUDA avec whisper-server, llama-server et une porte Caddy TLS 1.3 à jeton ; déploiement par \`cloud/runpod/deploy.sh\` ; banc synthétique mesuré en local (\`2026-09-25-cloud-bench-local.json\`). Aucun Pod n’a encore été provisionné.
- **Site** : page produit avec captures réelles de l’app.
- Index de toutes les preuves : \`docs/superpowers/evidence/README.md\`.

## Portes encore externes

- **Signature Apple** : le DMG est signé ad hoc, ni Developer ID ni notarisation ; Gatekeeper demandera clic droit → Ouvrir. L’archive iOS doit être signée avec une Team Apple.
- **Compte RunPod** : les chiffres GPU viendront du premier Pod ; l’image n’a pas été construite sur cette machine (pas de Docker).
- **Réseau hospitalier** : autorité de certification, MDM et enrôlement des appareils.
- **Conformité** : DPA fournisseur, avis DPO et validation clinique avant toute donnée patient réelle.

Données de démonstration synthétiques uniquement ; ne pas utiliser avec des données patient.
EOF

step "Corps de la release GitHub ($TAG, brouillon)"
cat "$DIST/$NOTES_NAME"

if (( PUBLISH_DRAFT )); then
  step "gh release create --draft $TAG"
  command -v gh >/dev/null || { print -u2 "gh introuvable"; exit 2; }
  gh release create "$TAG" --draft --title "VoxLocal $MAC_VERSION" --notes-file "$DIST/$NOTES_NAME" \
    "$DIST/$DMG_NAME" "$DIST/$IOS_NAME" "$DIST/$WIN_NAME" "$DIST/$SRC_NAME" "$DIST/$SUMS_NAME"
else
  print "\nLocal uniquement. Pour un brouillon GitHub : ./scripts/release.sh --publish-draft"
fi
