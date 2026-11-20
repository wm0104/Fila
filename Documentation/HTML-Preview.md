# DEB HTML preview

Accepted scope, based on `deb-dev` at `fd2e6e976f613324157f396d7c33c48a289490a9`.

- Tapping HTML/HTM opens an actual WKWebView; Open As > Text keeps the existing
  editor and save guard. XHTML remains source text in this first version.
- Chinese text, native scrolling and page layout are WebKit's, not extracted
  body text. Local CSS, images, JavaScript, HTML pages and anchors work inside
  the initial document's directory and its subdirectories.
- The initial directory is an immutable authorization capability, not a string
  prefix. Reject traversal, encoded separators, NUL, double decoding and all
  symlinks. The narrow directory open does not canonicalize again after a
  listing: an ancestor swapped for a symlink fails instead of changing the root.
  Capture it before initial format detection, then duplicate that same document
  FD for WebKit's main response. Serve bounded chunks from regular descriptors;
  filad opens them and returns FD-derived metadata, never file bytes.
- Internal navigation changes the current file details used by Text, Properties,
  Rename, Share and the breadcrumb. While a target is unresolved, omit the
  previous page's file actions. Relative opens retain the original root and
  permissions; Open As > Text never falls back to the original file on failure.
  Physical names are checked without links against the opened device/inode.
- No text resource is transcoded or given an invented UTF-8 charset. WebKit
  handles declared encodings and sniffing; the GBK HTML/CSS fixtures contain
  actual non-UTF-8 Chinese bytes.
- JavaScript and network access default off per preview lifetime. Menu toggles
  rebuild the renderer; closing/replacing it discards permission. Network access
  means HTTPS only. Local navigation cannot expand the root. An explicit
  external HTTPS link needs the existing confirmation card before presenting a
  system SFSafariViewController inside Fila, not an initial browser-app handoff.
  Other app URLs, preview downloads and execution are refused. Each renderer has
  its own native WKPreferences; peer connections remain disabled regardless of
  HTTPS/JavaScript permission. Unsupported/mismatched selectors or a failed
  disabled-state readback refuse rendering with Retry/Text. New windows are
  refused rather than receiving another or default WKWebView configuration.
- Reuse the tab shell, file menu, settings, navigation/overview animation,
  StatusView and AlertController. Failure is explicit, with manual Retry and
  Open As > Text. Never substitute extracted text or retry indefinitely.
- Keep the Office/iWork/RTF converter's own JavaScript rules, existing file
  operations, text editing, daemon authentication and trash semantics intact.
  This is the existing roothide iphoneos-arm64e DEB app, not an injection tweak.
  No IPA work, new dependencies, CI artifact expansion or automatic publishing.

## Confirmed in-app Safari interaction

The accepted browser interaction is a system SFSafariViewController presented
inside Fila after the existing Fila confirmation card, not an initial jump to the
default browser app. The card shows the validated HTTPS URL. Cancel/dismiss opens
nothing; Open waits for card dismissal before constructing Safari and presenting
it with the existing UIKit system-controller presentation and animation. A changed
generation, failed/closed preview, hidden navigation page or existing presentation
prevents a stale handoff. No browser or connection is prewarmed before consent.

Only the HTTPS URL is passed. Safari receives no local root descriptor, scheme
handler, WKPreferences or JavaScript/HTTPS preview permission. It uses its own
browsing policy and is not confined by the HTML preview toggles. Returning keeps
the existing preview/session; closing the HTML preview resets its permissions.
Fila does not dispatch the initial URL through UIApplication.open or private
Launch Services options. Subsequent navigation and the user's actions in Safari,
including opening its current page in a browser app, are managed by the system
component; this is not a global guarantee against app handoffs or browser traffic.
The HTML renderer still rejects direct custom-app URLs, downloads and new windows.

## Unresolved acceptance gates

- Confirmation cancellation, Open/dismissal ordering, stale/duplicate requests,
  initial system Safari presentation and return-to-preview behavior have not been
  exercised on a built app. Source wiring is not a passed browser/UI test.
- Content rules and CSP alone are not a WebRTC transport fence. The HTML-only
  native preference guard is implemented, but no setter call, WKWebView startup,
  RTC constructor exposure or ICE/STUN/TURN capture has been exercised here.
  JavaScript-on network isolation remains an unpassed runtime gate. Do not accept
  untrusted scripted input from static source evidence alone; deleting JavaScript
  globals is not a substitute for configuration-level isolation.

## Native RTC configuration evidence

`HTMLPreviewRTCPolicy` creates a fresh WKPreferences for each renderer, validates
selector presence, argument counts and exact Objective-C return/argument types,
then calls the matched `B` or `c` BOOL ABI with false and reads it back. It throws
before WKWebView creation on an unsupported signature or failed disabled-state
readback. HTTPS permission never changes this setting; no preference from another
Fila viewer is reused or modified. Both new-window policy and WKUIDelegate refuse
new pages without creating a default-configured WKWebView.

The implementation is based on the fixed WebKit `WebKit-7614.4.6.0.5` sources:

- [WKPreferencesPrivate.h](https://raw.githubusercontent.com/apple-oss-distributions/WebKit/WebKit-7614.4.6.0.5/Source/WebKit/UIProcess/API/Cocoa/WKPreferencesPrivate.h)
  declares the BOOL peer-connection property and iOS 11.3+ availability.
- [WKPreferences.mm](https://raw.githubusercontent.com/apple-oss-distributions/WebKit/WebKit-7614.4.6.0.5/Source/WebKit/UIProcess/API/Cocoa/WKPreferences.mm)
  connects its getter/setter to the native preference and preserves preferences
  when copying the configuration's preference object.
- [RTCPeerConnection.idl](https://raw.githubusercontent.com/apple-oss-distributions/WebKit/WebKit-7614.4.6.0.5/Source/WebCore/Modules/mediastream/RTCPeerConnection.idl)
  gates exposure on `PeerConnectionEnabled`.

This is SPI, not a public API guarantee across OS releases. The runtime checks
are necessary but not proof of absence of traffic, iOS 15 compatibility, renderer
startup or resolution of the older PID-0 launch failure. The `rtc-check.html`
fixture observes main/local/srcdoc/data/blob contexts without patching globals;
blocked or unobserved frames are not RTC passes. Controlled endpoint captures,
independent test builds for unavailable/mismatched selectors and failed readback,
and both HTTPS states remain required acceptance work.

## Validation boundary

Behavior tests belong to the existing FilaFormats, FilaFileOps, FilaClient and
FilaPrivileged host targets: format routing, URL validation, session policy and
real descriptor confinement. Privileged preview requests validate their immutable
path before any C-string encoding or root-FD duplication. Request-boundary tests
use actual XPC dictionaries (including an unchanged field after NUL rejection),
then call both real privileged LocalFileAccess methods and check EINVAL without
entering the transport. They do not stand in for an accepted daemon peer or a
successful cross-process resource open. These Swift tests have not run here.
Python toolbar checks cover integration contracts, not WebKit execution.
Runtime acceptance must exercise CSS/images/scripts, Chinese/scroll/layout,
local navigation/anchors, permissions/reset, blocked escapes, external-link
confirmation, failure/retry/text fallback, cancellation/close and Office/editor
regressions on a built DEB. No trash deletion/recovery is needed for validation.

The on-device workspace has no Swift, Python, Ruby, Node, make or Xcode runner.
Tests written here are not a demonstrated red/green TDD cycle. Full host tests,
Xcode 27.1 / SDK 27.1+ build, signing and floor audit require separately authorized
CI. A package build or static check is not proof that WebKit started or rendered.
Do not declare acceptance complete without observed HTML success on the device.
