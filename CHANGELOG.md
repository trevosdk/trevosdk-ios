# Changelog

All notable changes to the **TrevoSDK** Swift package are documented here.

## [Unreleased]

## [0.1.2] - 2026-11-20

### Added

- Remote paywall: `TrevoPaywall` (SwiftUI) and `TrevoPaywallViewController` (UIKit) show the page
  Trevo publishes under an id, in a WebView with no network, storage or permissions, and fall back
  to the app's own paywall when it can't show. Pages named by config download in the background,
  are checked against their SHA-256, and the current and previous version are kept on the device.
  A fallback tracks `$paywall_fallback` with its reason. iOS only.
- Remote paywall: a purchase the page makes tracks `purchase` with the paywall, product and page
  SHA-256, and no value, so revenue the app reports itself is never counted twice.
- Remote paywall: a page that fails while a purchase or restore is open doesn't show the app's own
  paywall over the store sheet. It waits, then closes if the purchase or restore went through, or
  falls back with the failure's reason if it didn't.
- `TrevoHTTPRequest.maxResponseBytes`: `URLSessionTransport` refuses a longer response body. The SDK
  sets it on page downloads; a custom transport should honor it too.

## [0.1.1] - 2026-11-14

### Added

- Text per language: `getParameter` with a `String` default reads a value served as
  `{"locales": {...}}` in the app's language, falling back from `pt-BR` to `pt` (never to another
  region) and to the default when no language matches.
- `setLocale(_:)` and `TrevoOptions.locale` set that language. Without either, it is the
  localization the app runs in. `setLocale` notifies `onChange` listeners.

## [0.1.0] - 2026-11-07

### Added

- `TrevoClient` with `getVariant`, `getParameter`, `track`, `identify`, `reset`, `ready`,
  `onChange`, `flush` and `shutdown`, assigning identically to every other Trevo SDK.
- Persisted identity, assignments, config and event queue; refresh on foreground and flush on
  background; `minAppVersion` gating from `CFBundleShortVersionString`; a privacy manifest.
