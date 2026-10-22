# Contributing to Awayke

Thanks for your interest. Awayke is a deliberately small, single-purpose menu-bar app,
so the bar for changes is "does it keep the thing small, honest, and native?"

## Ways to help

- **Report a bug**: use the bug-report issue form. Include your exact macOS version
  (`sw_vers`), your Mac model (`sysctl -n hw.model`), and what `pmset -g | grep SleepDisabled`
  reports before/after the problem.
- **Request a feature**: use the feature-request form. Features that grow the privilege
  surface (more sudo, a helper daemon, kexts) are unlikely to land; the security model is a
  core feature, not an obstacle.
- **Improve docs**: README and documentation fixes are very welcome.
- **Code**: bug fixes and small, focused improvements.

Awayke is a fork of [Sleepless](https://github.com/Aboudjem/Sleepless) by Adam Boudjemaa.
Fixes to the shared keep-awake core may be worth offering upstream too.

## Building locally

No Xcode project, just the Command Line Tools:

```sh
git clone https://github.com/Solomon-69/Awayke.git
cd Awayke
./build.sh            # builds ./build/Awayke.app, ad-hoc signed
open build/Awayke.app
```

`./install.sh` additionally installs the passwordless grant + login item (it prints exactly
what it writes). `./uninstall.sh` backs it all out and proves the grant is revoked.

## Coding guidelines

- **Keep it native.** Awayke uses AppKit and SwiftUI only. No third-party dependencies and
  no bundled frameworks.
- **Zero warnings.** The build must compile clean:
  ```sh
  swiftc -O -parse-as-library -target arm64-apple-macos26.0 \
    -framework AppKit -framework ServiceManagement -framework SwiftUI -framework IOKit \
    App.swift Glyph.swift PopoverView.swift SettingsView.swift SmoothSwitch.swift -o /tmp/Awayke
  ```
  CI runs the equivalent compile on every push/PR.
- **Match the surrounding style.** Read `App.swift` first. Keep comment density, naming, and
  the "read back the real system state, never assume" discipline.
- **No personal paths or usernames** in scripts, the sudoers template, or install commands.
  The grant is generated from `$(id -un)` at install time.
- **Verify on a real machine.** Awayke is verified on macOS 26 (Tahoe) on Apple Silicon.
  If you test on other versions/hardware, say so in the PR.

## Pull requests

1. Fork, branch from `main`.
2. Keep the diff focused; one logical change per PR.
3. Make sure the build is clean and the app launches.
4. Fill in the PR template (what changed, how you tested, macOS version).

By contributing you agree your work is licensed under the [MIT License](LICENSE).
Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).
