# Changelog

All notable changes to the **TrevoSDK** Swift package are documented here.

## [Unreleased]

## [0.1.0] - 2026-11-07

### Added

- `TrevoClient` with `getVariant`, `getParameter`, `track`, `identify`, `reset`, `ready`,
  `onChange`, `flush` and `shutdown`, assigning identically to every other Trevo SDK.
- Persisted identity, assignments, config and event queue; refresh on foreground and flush on
  background; `minAppVersion` gating from `CFBundleShortVersionString`; a privacy manifest.
