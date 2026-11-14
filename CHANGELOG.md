# Changelog

All notable changes to the **TrevoSDK** Swift package are documented here.

## [Unreleased]

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
