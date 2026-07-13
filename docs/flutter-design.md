# Flutter human-centered design

This document defines the product and interaction goals for Zuko's shared
Flutter client. It complements the repository-wide [design principles](design.md)
and [roadmap](roadmap.md): those documents define product and trust boundaries;
this one explains how the graphical client should feel and how contributors
should evaluate changes.

The client serves phones, tablets, browsers, and desktop windows from one
implementation. Shared code should preserve one mental model without forcing
every platform into the same physical layout or input pattern.

## Human outcomes

A successful client lets someone:

1. pair a machine without understanding Iroh, tickets, tokens, or node IDs;
2. recognize the intended host and this client device later;
3. start and control a real terminal with the input method they have;
4. understand whether a connection is waiting, retrying, attached, ended, or
   rejected, and know what to do next;
5. distinguish local organization from host-side authorization and revocation;
6. recover from ordinary mistakes, denied permissions, network changes, and
   application lifecycle changes without losing identity unexpectedly.

Optimize for confidence and recoverability, not feature count. A remote shell
is a high-consequence tool: ambiguity about which host is active or whether
access was revoked is more harmful than an extra step.

## Interaction principles

### Prefer recognition over recall

- Pair from the QR code the host already displays, with the two-word code as a
  complete fallback.
- Use host-provided labels initially; do not ask the user to invent a host name
  during pairing.
- Let people rename saved hosts later and search by friendly name, original
  host label, or node ID.
- Give this client a recognizable, editable device name while retaining a
  short identity-derived suffix to avoid collisions.

Names are aids for people, not security identities. Never weaken endpoint,
token, or node-ID validation because a friendly label matches.

### Make one next action obvious

Empty, loading, connected, recoverable-error, and terminal-ended states should
each have one visually primary next action. Secondary choices remain available
without competing with it. Do not put onboarding instructions in a narrow
sidebar when the otherwise-empty main pane can explain them clearly.

### Keep fallback paths complete

QR scanning is convenient, not required. Camera denial, unsupported desktop
platforms, malformed QR content, and scanner failure must still leave typed
entry available. The same rule applies to touch, mouse, keyboard, clipboard,
and accessibility input: platform enhancement must not become the only path.

### State the consequence before destructive actions

Use precise verbs:

- **Rename** changes a local display name.
- **Forget** removes a saved host from this client but does not revoke access.
- **Revoke** removes host-side authorization.
- **Reset** rotates trust state and requires re-pairing.

Confirmation and detail text must say which side changes. Do not imply that
forgetting locally has secured a lost or compromised device.

### Make status actionable

Status text should answer three questions where possible:

1. What is happening?
2. Does the user need to act?
3. What action can resolve it?

Prefer “Host rejected this client. Pair it again.” over a transport exception
or protocol code. Keep the underlying distinction in logs and tests, but do
not require it to understand the screen. Preserve input when retry is useful.

### Be compact, not cramped

Terminal work benefits from density, especially on small screens. Density is
acceptable when labels remain legible, state remains distinguishable, and the
same action is available through a larger menu, keyboard, or system affordance.
Do not reduce spacing merely to show more inactive chrome.

### Adapt layout and input, not product meaning

- Narrow layouts use a drawer and the main pane for the current task.
- Wide layouts keep a persistent, collapsible connection sidebar.
- Phones may use bottom sheets where desktops use anchored menus or popovers.
- Touch dragging scrolls; touch selection starts with long press. Mouse and
  keyboard selection retain desktop conventions.
- Terminal keys must go through `flterm`'s typed `Key` API, not handwritten
  escape sequences.

The action and result should remain equivalent across these presentations.

### Protect terminal correctness and trust boundaries

UI convenience must not bypass pairing-code parsing, endpoint validation,
`ATTACHED` validation, guarded multiline paste, supported-link filtering, or
secure storage. Validate untrusted input near its boundary and fail closed.
Avoid collecting identifiers or adding file, network, or background capability
only to improve presentation.

## Current interaction model

This section records intentional behavior that already exists. Update it when
the implementation changes.

### First run and pairing

- The empty main pane welcomes the user and offers QR scanning when supported
  plus typed-code entry everywhere.
- The QR payload is the raw one-time pairing code and is accepted only through
  the same `PairingCode.parse` validation as typed input.
- Pairing asks only for the code. The saved host starts with the host-provided
  label; a local rename is available afterward.
- Invalid scans are ignored with inline guidance. Failed claims retain retry
  and manual fallback instead of dismissing the flow.
- Camera access exists only on supported targets. There is no operating-system
  deep-link registration for pairing.

### Saved hosts and client identity

- Saved hosts are bounded and displayed in compact rows. Duplicate subtitles
  are suppressed.
- Local search is immediate, case-insensitive, and matches all query terms
  across the friendly name, original label, and node ID.
- The selected host uses both icon treatment and row state; selection must not
  rely on color alone.
- **This device name** is suggested from a non-secret descriptive property,
  can be edited, and is persisted in protected client state. New host labels
  use `zuko-<device-name>-<identity-suffix>`.
- Changing the device name affects new pairings. Re-pairing an existing host
  safely replaces its old authorization label for the same token.

### Terminal surface

- `flterm` and `libghostty` own terminal parsing, rendering, selection, and
  key encoding. Zuko should not create a parallel terminal behavior layer.
- The accessory row is currently 24 logical pixels high, with width-aware
  28–36 pixel slots. These are tested compact-mode constraints, not a general
  recommendation for all controls.
- Copy and paste are contextual; less common actions live in overflow.
- The overflow opens Home, End, Page Up, Page Down, Insert, Delete, and F1–F12
  in a phone bottom sheet or compact desktop popover. Arrow buttons repeat
  after a deliberate hold delay instead of requiring rapid tapping.
- Multiline paste remains guarded. Supported terminal links are limited to
  absolute HTTP and HTTPS URLs.
- Touch and stylus positions follow alternate-screen scroll conversion so
  mouse-aware programs receive wheel events at the intended terminal cell.
  Long press gives platform feedback when touch selection becomes armed.
- Terminal output exposes a readable visible viewport and focus action to
  assistive technology, but continuous output is not a live region because
  announcement spam would make the client unusable.

### Responsive behavior

- `760` logical pixels is the current wide-layout breakpoint.
- Until the user chooses a terminal size, the tested defaults are 7 logical
  pixels on narrow layouts and 10 on wide layouts. User customization then
  takes precedence within the supported range.
- These constants protect known small-screen layouts. Change them only with
  narrow, wide, text-scale, and physical-device evidence.

## Accessibility and inclusive input

Accessibility is behavior, not a final semantics pass. Every interactive
change should consider:

- meaningful labels, roles, values, selected state, and focus order;
- keyboard-only activation, dismissal, and traversal;
- TalkBack, VoiceOver, and desktop screen-reader output;
- text scaling without clipped actions or unreachable content;
- contrast in light and dark themes and state cues beyond color;
- reduced-motion preferences for nonessential transitions;
- touch, stylus, mouse, trackpad, hardware keyboard, and software keyboard;
- errors that remain understandable without seeing an icon or color.

Platform target-size guidance is the default. The compact terminal accessory
row is an intentional exception because terminal viewport height is scarce;
important actions therefore also need keyboard or menu access. A future
comfortable-control mode should improve this trade-off without silently
changing the established compact layout.

## Writing style

- Use sentence case and familiar words.
- Name the object: “Pair host”, “Forget office workstation”, “Edit device
  name”.
- Keep primary buttons verb-first and specific; avoid generic “OK” when the
  action can be named.
- Do not expose raw exceptions, ALPN names, token language, or package details
  as the only explanation.
- Use inline validation for fixable input. Use dialogs for decisions and
  snackbars for brief confirmation, not for essential instructions.
- Never claim success before protected state has been saved.

## Contributor workflow

Before implementing a Flutter interaction, write down:

1. the human problem and the critical journey it belongs to;
2. the default, empty, busy, success, recoverable-error, permanent-error, and
   cancellation states that apply;
3. what happens on narrow and wide layouts;
4. how touch, mouse, keyboard, and assistive technology reach the action;
5. whether permission, storage, network, clipboard, process, or trust
   boundaries change;
6. how the person recovers and whether their input or identity is preserved;
7. the smallest automated and physical-device evidence that demonstrates the
   result.

Prefer an existing Flutter, Material, Yaru, or `flterm` affordance over a new
dependency. A package is justified by a required capability and supported
target matrix, not by a single convenient widget.

### Code map

- `flutter/lib/src/app.dart`: responsive shell, welcome state, saved hosts,
  connection settings, and terminal accessory UI.
- `flutter/lib/src/pairing_screen.dart`: scanner and typed pairing journey.
- `flutter/lib/src/app_controller.dart`: persisted actions and user-visible
  operation status.
- `flutter/lib/src/model.dart` and `storage.dart`: migration-safe preferences,
  identity, and saved-host state.
- `flutter/lib/src/client_name.dart`: safe friendly client labels.
- `flutter/packages/flterm/`: terminal rendering and cross-input behavior.

### Expected evidence

Automated checks should cover the smallest stable boundary:

- pure tests for parsing, normalization, sizing, state migration, and action
  selection;
- widget tests for validation, progress, retry, focus, semantics, and layout;
- `flterm` regression tests for terminal input, rendering, scrolling, and
  selection behavior;
- web builds for conditional imports, CSP, and WASM compatibility;
- native builds and representative physical-device checks before promotion.

Exercise at least a small phone width, the wide-layout boundary, a desktop
window, light and dark themes, system text scaling, keyboard traversal, and the
relevant touch or pointer interaction. Passing analysis alone is not UX
evidence.

Run `just flutter-check` for shared changes and the relevant platform build from
[Building clients](building-clients.md). Record environmental build blockers
rather than treating an unattempted build as success.

## High-value follow-up work

This is an evaluation order, not a release promise. The roadmap remains the
source of product commitments.

### Next

1. Perform keyboard and screen-reader journey tests for first pairing, host
   search, connection recovery, terminal focus, and forget-versus-revoke
   guidance.
2. Verify QR scanning, lifecycle changes, client-state migration, and terminal
   touch behavior on representative physical devices before target promotion.

### After those foundations

- Improve denied-camera and restricted-permission recovery with a clear typed
  fallback and platform-settings action where the platform supports one.
- Offer a comfortable terminal-control density without changing the tested
  compact default or responsive terminal font behavior.
- Map connection failures to a small, tested set of plain-language causes and
  next actions while retaining safe diagnostic detail.
- Add an undo window for local host forgetting where state can be restored
  without implying host-side revocation.
- Expand resize and text-scale tests around the sidebar breakpoint, pairing
  flow, dialogs, and terminal overlays.
- Prepare strings for localization once there is a concrete translation and
  maintenance plan; avoid constructing user-visible sentences from fragments
  in the meantime.
- Use structured physical-device test scripts and issue feedback rather than
  adding behavioral analytics by default.

When choosing among these, fix blocked recovery, inaccessible operation, and
misleading trust state before adding visual polish.
