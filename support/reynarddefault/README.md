# ReynardDefault (companion jailbreak tweak)

This directory contains a jailbreak tweak that makes Reynard usable as the system default browser on iOS/iPadOS 14–17, including devices where the Settings "Default Browser App" list does not offer Reynard natively.

When installed and enabled, any link that would open in Safari (or other popular browsers) is intercepted at the SpringBoard level and opened in Reynard instead. The toggle lives directly in the main Settings list (inline switch, no preference bundle) with an optional Control Centre toggle.

Based on [guacforlife/ReynardDefault](https://github.com/guacforlife/ReynardDefault) (GPL-3.0), hardened for iPadOS 15.1: the upstream preference pane crashed the Settings app on tap on some iPadOS versions, so the preference bundle was replaced with a native inline `PSSwitchCell`.

## Building

Requires [Theos](https://theos.dev/).

```bash
cd support/reynarddefault
make rootless   # Dopamine / Roothide / palera1n rootless
make rootful    # unc0ver / palera1n rootful / Taurine
```

`.github/workflows/build-tweak.yml` builds both variants automatically on GitHub Actions.

## Note

Reynard's Jailbroken/TrollStore builds already embed the `com.apple.developer.web-browser` entitlement (see `browser/Reynard/Entitlements/Reynard.private.entitlements`). Depending on the iOS version, that may be enough for Reynard to appear natively under *Settings → Safari → Default Browser App* — check there before installing this tweak.
