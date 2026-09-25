# iOS stability and privacy hardening

The portable client now requires an explicit pairing code before either Bonjour or
manual connection. Bonjour results are displayed as untrusted candidates; there is
no automatic connection to an arbitrary service. TLS is enabled by default for new
installations and is sent to the Core client for both discovery and manual paths.
Existing installations keep their explicit transport preference so an upgrade does
not silently break a managed deployment. The server certificate must chain to an
iOS trusted CA; certificate pinning remains a deployment requirement for PHI.

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
