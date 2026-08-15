# Pairing and connection flow

This page walks through the end-to-end pairing experience in the Zuko
clients: installing the host, claiming a one-time share code, and opening
the terminal session.

The screenshots are rendered deterministically from the real widget tree
(Yaru themes, bundled fonts, and the terminal widget) by
`flutter/test/screenshot_flow_test.dart`. Regenerate them with
`just screenshots` whenever the pairing or connection UI changes.

## 1. First run

The welcome screen gives the two host-side commands: install Zuko, then
run `zuko share` to mint a one-time share code.

![Welcome screen](images/welcome.png)

## 2. Claim the share code

On a phone, point the camera at the QR code that `zuko share` prints. The
animated viewfinder brackets the code; a failed claim offers both a retry
and the typed fallback.

![Camera pairing](images/pairing-scan.png)

Entering the code by hand accepts the canonical two-word form. Pasting
works with the full `zuko share` output — the code is extracted from
merged stdout/stderr, `zuko claim` lines, or `zuko://pair` URIs.

![Manual pairing](images/pairing-code.png)

A successful claim confirms the host name before the connection opens.

![Pairing confirmation](images/pairing-confirmed.png)

## 3. Connect to a saved host

Selecting a saved host opens a terminal tab. While the peer connection is
established, the session overlay reports progress and the tab shows the
busy state.

![Connecting](images/connecting.png)

If the link drops, the overlay counts down to the automatic reconnect
attempt; *Retry now* reconnects immediately.

![Reconnect countdown](images/retrying.png)

An attached session brings up the terminal with the accessory bar for
touch devices and extended keys.

![Attached session](images/connected.png)

## Re-pairing and revocation

A host that rejects the saved ticket shows a *Pair again* action. Pairing
again records the fresh ticket and the host-side client label, which the
host details dialog exposes as a `zuko rm <label>` revocation command.
