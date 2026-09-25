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
  "L’identité du serveur a changé. Vérifiez le poste avant de réessayer." The
  pin is not replaced automatically.
- **First use (TOFU).** Without a pin, a certificate that chains to a CA trusted
  by iOS is accepted. Otherwise the connection fails with `untrustedServer` and
  the sheet "Vérifier l’identité du serveur" shows the fingerprint. "Faire
  confiance et connecter" stores the pin and reconnects; "Annuler" (or swiping
  the sheet away) stores nothing.
- **MDM CA path.** A hospital that installs its own CA profile on managed
  iPhones gets system-trusted certificates: the first connection needs no
  confirmation and no pin is stored, so the CA stays in charge of rotation.
- **Forget.** The connection sheet shows "Identité épinglée · <4 premiers
  groupes>" for the current server and a destructive "Oublier ce serveur"
  action behind a confirmation dialog. It deletes the pin and disconnects; the
  next connection asks for confirmation again. Use it after a legitimate
  certificate change on the server, once the new fingerprint has been checked
  on the Mac.

To screenshot the confirmation sheet without a server, build Debug with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` (the project does not define it)
and launch with `-VoxLocalDebugTrustSheet 1`; the hook is compiled out
otherwise. Evidence: `docs/superpowers/evidence/2026-09-25-ios-trust-sheet.png`.

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
