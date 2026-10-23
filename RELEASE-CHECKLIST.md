# Release checklist

Steps for publishing Awayke as the public repository `Solomon-69/Awayke`. Nothing here has
been pushed yet.

## 1. Start the public repository from a fresh history

The private history of this folder should not be published as it is. Earlier private work on
these apps included personal details such as an Apple ID used for signing, so the public
repository should start from one clean commit:

```sh
# from a clean checkout of the current main branch
git checkout --orphan public-main
git add -A
git commit -m "Awayke 1.4.0, based on Sleepless by Adam Boudjemaa"
# check before pushing: no personal emails, Apple IDs, Team IDs or personal paths
git grep -nIiE '@(gmail|icloud|me|outlook)\.com|apple ?id|/Users/' -- ':!RELEASE-CHECKLIST.md' || echo "clean"
git remote add public https://github.com/Solomon-69/Awayke.git
git push public public-main:main
```

Adam Boudjemaa's credit stays in `LICENSE`, `README.md` and `CHANGELOG.md`, so the fresh
history does not lose the attribution the MIT licence asks for. Linking the original
repository (https://github.com/Aboudjem/Sleepless) from the GitHub description is a nice touch.

## 2. Before the first public push

- [ ] `git grep` check above prints `clean`
- [ ] `LICENSE` still has both copyright lines (Adam Boudjemaa and Solomon)
- [ ] README badges and links point at `Solomon-69/Awayke`
- [ ] Screenshots in `docs/img/` are current
- [ ] `design-options.html` and `build/` are not tracked

## 3. Repository settings on GitHub

- [ ] Description: "Keep your MacBook awake with the lid closed. Based on Sleepless."
- [ ] Topics: `macos`, `menu-bar`, `menubar-app`, `caffeinate`, `keep-awake`, `swift`, `swiftui`
- [ ] Social preview image: `assets/social-preview.png`
- [ ] Private vulnerability reporting: on (Settings > Code security)
- [ ] Discussions on (the issue form links to them)

## 4. Optional: signed and notarised builds

Add these repository secrets (Settings > Secrets and variables > Actions). The release workflow
uses them when all are present and skips signing when they are not:

`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY`,
`NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`.

Details are at the top of `.github/workflows/release.yml`. Never put these values in a file.

## 5. Cutting a release

- [ ] Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`
- [ ] Move the `[Unreleased]` notes in `CHANGELOG.md` under the new version
- [ ] Tag and push: `git tag v1.4.0 && git push public v1.4.0`
- [ ] Check the release has `Awayke.dmg`, `Awayke-<version>.zip` and `SHA256SUMS`
- [ ] On a second Mac: install from the dmg, switch on, close the lid, confirm it stays awake, run `./uninstall.sh`
