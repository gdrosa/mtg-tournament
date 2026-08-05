# Contributing

Thanks for improving MTG Tournament. Keep changes focused on reliable,
offline-first local events and preserve the trust boundaries described in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Setup

Use Flutter `3.44.2` and JDK 17, then run:

```shell
flutter pub get
flutter doctor
```

The pure Dart server can be developed without an Android device:

```shell
dart run bin/dev_server.dart 8091
```

## Before submitting a change

```shell
dart format lib test bin
flutter analyze
flutter test
```

Add regression coverage when changing:

- Swiss pairing or tiebreak calculations
- match state transitions and round gating
- authorization, snapshots, or HTTP routes
- persistence and backup import/export
- deck ownership or tournament-lock behavior

## Design rules

- Keep `lib/shared/` deterministic and free of UI or filesystem dependencies.
- Treat `ServerController` as the authoritative mutation boundary.
- Return viewer-specific snapshots; do not place host-only details in public data.
- Make durable mutations persist before relying on a UI notification.
- Keep the browser client build-free unless there is a compelling product reason to change it.
- Preserve typed deck text when an online card lookup fails.
- Do not add a runtime internet dependency to tournament play.

## Repository hygiene

Do not commit tokens, `.env` files, keystores, `android/key.properties`, device
screenshots, interview recordings, local assistant settings, or generated build
directories. Curated documentation images belong in `docs/images/`.

Keep application lockfiles committed. Do not perform unrelated major dependency
upgrades in a feature or bug-fix pull request.
