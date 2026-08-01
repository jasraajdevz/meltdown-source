# MELTDOWN — source

A nuclear reactor control-room simulator, written in Flutter with **zero pub
dependencies**. Targets iOS (primary) and web.

**▶ Play: https://jasraajdevz.github.io/meltdown/**

## What it is

You are the night-shift operator of a pressurized water reactor. Start it from
cold shutdown, take it critical, put megawatts on the grid, follow the
dispatcher, and still be standing at the end of the watch.

The physics are real enough that real operating procedure works:

- **Negative temperature feedback** and **prompt Doppler** make the plant
  self-stabilizing — it settles rather than running away, so death is never on a
  timer. The protection system trips before anything breaks.
- **Coolant pump heat** warms the plant to operating temperature before it ever
  goes critical, which is how an actual startup begins.
- **Fuel burnup** eats reactivity across a fuel cycle, so you dilute boron a
  little further every shift until you have to schedule a refuelling outage.
- **Xenon**, thermal inertia, damped instruments, a 20-tile annunciator with
  ACK/SILENCE/RESET/TEST, and a synchroscope you have to catch in phase.

## Layout

| Path | Purpose |
|---|---|
| `lib/main.dart` | The entire game — physics, controls, rendering |
| `lib/storage_*.dart` | Save file (native) vs localStorage (web) |
| `lib/audio_*.dart` | Web Audio synthesis vs haptics |
| `lib/speech_*.dart` | Manual read-aloud (web only) |
| `test/game_test.dart` | Physics, economy, controls, sanity |
| `test/layout_test.dart` | Overflow guard at five iPhone sizes |
| `test/storage_test.dart` | Save/resume/corruption |

The four `*_web` / `*_io` pairs exist only because iOS and web need different
sinks; everything else lives in one file on purpose.

## Working on it

```bash
flutter test --platform chrome        # 91 tests (web-only: js_interop)
flutter run -d chrome
flutter run -d iphone                 # needs full Xcode
```

Deploy the web build:

```bash
flutter build web --release --base-href /meltdown/ --pwa-strategy=none
# then copy build/web into the gh-pages branch of jasraajdevz/meltdown
```

## Branches

- `main` — current build
- `hardcore-archive` — the pre-revamp difficulty (no tutorial, constant
  screaming, canteen only between shifts)
