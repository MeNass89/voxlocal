# iOS stability and privacy hardening

The portable client now requires an explicit pairing code before either Bonjour or
manual connection. Bonjour results are displayed as untrusted candidates; there is
no automatic connection to an arbitrary service. TLS is enabled by default for new
installations and is sent to the Core client for both discovery and manual paths.
Existing installations keep their explicit transport preference so an upgrade does
not silently break a managed deployment. Server identity is checked by certificate
pinning with trust-on-first-use confirmation (see "Confiance serveur" below).

## Confiance serveur

The client replaces the default TLS certificate check with its own decision,
taken inside `sec_protocol_options_set_verify_block` during the TLS 1.3
handshake. The connection never reaches `.ready` for a refused identity, so no
PAIR frame, pairing code or audio byte leaves the phone. The regression suite
asserts this against a Python TLS fixture that records zero application bytes.

- **Fingerprint.** SHA-256 of the server's leaf certificate in DER form (the
  certificate, not the SPKI). It is shown as uppercase hex in groups of four,
  the format VoxLocal displays on the Mac, and carried as base64 in error
  messages and in the Keychain.
- **Pin storage.** One device-only Keychain item per server, service
  `com.voxlocal.remotescribe.portable`, account `pin:<key>`, where `<key>` is
  the Bonjour service name for a discovered server and `host:port` for a manual
  connection. If the Keychain refuses the write, the pin is kept in memory for
  the current run and the UI says so. An unreadable pin (locked device) stops
  the connection instead of falling back to a first-use prompt.
- **Pinned server.** Only the pinned certificate is accepted; hostname and CA
  checks are skipped on purpose, because the pinned certificate is the server's
  identity. A different certificate fails with `pinMismatch` and the message
  "L’identité du poste a changé. Vérifiez-le avant de réessayer." The
  pin is not replaced automatically (a scanned pairing link is the one
  exception, see "Appairage par QR code").
- **First use (TOFU).** Without a pin, a certificate that chains to a CA trusted
  by iOS is accepted. Otherwise the connection fails with `untrustedServer` and
  the sheet "Vérifier l’identité du poste" shows the fingerprint. "Faire
  confiance et connecter" stores the pin and reconnects; "Annuler" (or swiping
  the sheet away) stores nothing.
- **MDM CA path.** A hospital that installs its own CA profile on managed
  iPhones gets system-trusted certificates: the first connection needs no
  confirmation and no pin is stored, so the CA stays in charge of rotation.
- **Forget.** The connection sheet shows "Identité épinglée · <4 premiers
  groupes>" for the current server and a destructive "Oublier ce poste"
  action behind a confirmation dialog. It deletes the pin and disconnects; the
  next connection asks for confirmation again. Use it after a legitimate
  certificate change on the server, once the new fingerprint has been checked
  on the Mac.

To screenshot the confirmation sheet without a server, build Debug (the
project defines `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` for Debug only)
and launch with `-VoxLocalDebugTrustSheet 1`; the hook is compiled out of
Release. Evidence: `docs/superpowers/evidence/2026-09-25-ios-trust-sheet.png`.

## Appairage par QR code

VoxLocal shows a QR code in Remote Scribe on the poste. It encodes
`remotescribe://pair?name=<Bonjour service name>&code=<dashless code>&fp=<base64 SHA-256 of the DER certificate>`.
`PairingLink` parses it strictly: scheme `remotescribe`, action `pair`, no
user, port or fragment, each of `name`, `code` and `fp` present exactly once,
values percent-decoded, a name of 1 to 63 UTF-8 bytes without control
characters or surrounding spaces, a code of 6 to 64 characters from
`A–Z a–z 0–9 - _`, and a fingerprint that decodes to exactly 32 bytes. Anything
else is rejected, never repaired. `ios/RemoteScribePortableTests/PairingLinkTests.swift`
covers the valid form (raw and percent-encoded base64), missing fingerprint,
bad base64, wrong scheme or action, invalid code and ambiguous name.

`PortableClientModel.applyPairingLink(_:)`:

- refuses while a dictée is starting, running or being processed;
- stores the code in the Keychain (same item as a typed code) and forces TLS;
- stores the fingerprint as the pin of `pin:<name>`, the same key a Bonjour
  connection uses. A different existing pin is replaced, because the code was
  read from the poste's own screen, which is the trust anchor the first-use
  sheet asks the user to compare against. The status line says when a pin was
  replaced. A Keychain refusal keeps the pin in memory, as for the sheet;
- connects as soon as a discovered server has that exact Bonjour name
  (case-insensitive fallback), then clears the pending name. Discovery is
  otherwise still never trusted: without a scanned link the user picks the
  server.

`QRPairingView` uses `AVCaptureSession` with `AVCaptureMetadataOutput` limited
to `.qr`. Unrelated QR codes are ignored silently; a pasted link that does not
parse shows an explanation. Permission refused shows "Caméra refusée" with an
"Ouvrir Réglages" button. Without a camera (the simulator) it shows "Caméra
indisponible dans le simulateur". In every case a "Coller un lien d’appairage"
field and the system paste button accept the same URL.
`NSCameraUsageDescription` states the camera is used only for this code.

## First run and empty states

`OnboardingView` is shown while `UserDefaults` `portable.onboardingDone` is
false: three pages in a native page `TabView` (system page dots), each with an
SF Symbols diagram, a title and one sentence. "Continuer"/"Passer" on the
first two pages, "Scanner le code"/"Plus tard" on the last; every choice marks
onboarding done, and "Scanner le code" opens the scanner on the main screen.
Page changes are animated only without Reduce Motion. Buttons are at least
50 pt tall; each page is one VoiceOver element announcing "Étape n sur 3".

When discovery finds no poste for 10 s (`PortableClientModel.noServerDelay`),
the connection card becomes "Aucun poste trouvé sur ce Wi-Fi" with "Scanner le
code du poste" and "Saisir l’adresse". It reverts as soon as a service appears
or a connection starts, and the timer re-arms after "Rechercher un poste à
nouveau". The engine picker is hidden until a poste accepts the pairing: its
list comes from `PairResponse.availableBackends`, and a single engine is shown
as one line of text instead of a one-segment picker. Connected with an empty
history, the recorder shows "Maintenez l’iPhone à 20 cm, parlez normalement."

## Result feedback

A completed dictée triggers `UINotificationFeedbackGenerator.success`, scrolls
the new result into view and outlines it in green for 1.5 s (no fade with
Reduce Motion). `PortableResult.posteDelivery` records what the poste did,
read from its final status message: "collée" → "Collé sur le poste",
"copié" → "Copié sur le poste"; the field is optional so older history still
decodes. "Copier" writes the displayed text to the local pasteboard only
(`localOnly`, no Handoff) with a two-minute expiry, so clinical text does not
linger; "Partager" is unchanged.

## iPad

With a regular horizontal size class the app uses `NavigationSplitView`:
history in the sidebar (with its own empty state and "Effacer"), recorder and
connection in the detail column. A compact width, including iPad Slide Over or
a narrow split screen, keeps the single-column phone layout.

## Screenshot hooks (Debug only)

- `-portable.onboardingDone YES` skips onboarding (standard `UserDefaults`
  argument, works in every configuration).
- `-VoxLocalDemoState connected` seeds a paired poste named "Poste
  Cardiologie" and one synthetic result, then after 3 s scrolls to it and
  shows the completion outline, held on (not cleared after 1.5 s) so the
  screenshot can catch it. Nothing is sent over the network.
- `-VoxLocalDebugScanner 1` opens the pairing scanner at launch.

In the simulator, an app built with `CODE_SIGNING_ALLOWED=NO` has no
Keychain entitlement and every Keychain call returns `-34018`; the app then
shows its "trousseau" warning, as designed. Evidence screenshots therefore
use an ad-hoc signed simulator build with a temporary entitlements file
declaring `application-identifier` and `keychain-access-groups`
(`CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=<file>`); the project itself is
unchanged.

Evidence (2026-09-25, iPhone 18 Pro and iPad Air 11-inch (M4), iOS 27):
`2026-09-25-ios-onboarding.png`, `-ios-home-no-server.png`,
`-ios-qr-pairing.png`, `-ios-home-connected.png`, `-ios-result.png`,
`-ios-ipad-split.png` under `docs/superpowers/evidence/`. The connected and
result screens use the demo seed: this machine has no Simulator.app to drive
the manual connection to the Python mock host.

## Audio and sessions

Audio stop closes tap admission, drains already accepted PCM and converter output,
then sends STOP. Start/stop are generation guarded, permission callbacks are stale
safe, and interruption, route loss and media-service reset fail the operation and
close the transport so the next attempt can reconnect. Connection, start and
processing
operations have bounded deadlines (20 seconds, 30 seconds and 5 minutes). A
completed status abandons the Core session before returning to the ready state.

History persistence is opt in (`portable.persistHistory`); the default is memory
only. Enabling it stores the encoded history in a device-only Keychain item. Turning
it off or clearing history creates a purge tombstone before deleting Keychain data;
failed deletion is reported and the tombstone prevents reloading old text on the
next launch. Legacy UserDefaults history is deleted without migration.

Keychain status codes are checked and surfaced. If the pairing secret cannot be
stored, it remains in memory for the current run and the UI says so. The UI calls
the peer a server/poste and requires a code, instead of assuming a Mac.

Validation now includes a real unsigned device build with Xcode 27.0 and the
iOS 27 SDK:

```bash
xcodebuild -quiet \
  -project ios/RemoteScribePortable.xcodeproj \
  -scheme RemoteScribePortable -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/voxlocal-ios-derived \
  CODE_SIGNING_ALLOWED=NO build
```

The canonical project and the complete exported iOS project both pass this
build. The machine sees the paired physical target the paired iPhone as
`iPhone16,1`; the iOS 27 Simulator runtime is installed, although the first
third-party app install remained blocked by the CoreSimulator service. The free
Apple account
signing step remains local to Xcode: select the user's Personal Team under
Signing & Capabilities, then use the device destination. The repository does not
contain a development team or provisioning profile.

The UI uses native Liquid Glass on iOS 26 and newer for the primary recording
action, the connection action, and the compact action group. The recording and
transcription surfaces keep a contrast-controlled material fallback; the
segmented Picker, Form, navigation bar and Toggle remain native system controls
so iOS can adapt them to Reduce Transparency and Increase Contrast. All custom
glass calls are guarded with `#available(iOS 26.0, *)`, preserving iOS 16
deployment. Reduced Motion disables the audio-level animations.
