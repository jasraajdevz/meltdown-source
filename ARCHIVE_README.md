# MELTDOWN — hardcore build (archived 2026-08-01)

This is the untouched "hard" version, saved before the easier/tutorial revamp.
It is a complete, working project — nothing was removed.

What makes this one the hard one:
- No tutorial. The checklist under the mimic is all the guidance there is.
- Screams fire on a fixed 25-75s timer no matter how well the plant is running,
  so pressure is constant rather than earned.
- The canteen can only be bought from between shifts. Run out mid-watch and
  that is simply the rest of your shift.
- Long-form operator's manual.

To run it:
    cd meltdown_HARDCORE_archive
    ~/development/flutter/bin/flutter run -d chrome
    # or: flutter test --platform chrome     (77 tests)

To make it the live version again, copy lib/ and test/ back over
~/Downloads/meltdown_reactor and redeploy.
