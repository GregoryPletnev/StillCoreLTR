# Releasing StillCore LTR

Releases are published by GitHub Actions
([.github/workflows/release.yml](../.github/workflows/release.yml)) when you push a
tag `ltr-v<version>`. The workflow builds `StillCoreLTR.dmg`, attaches it and its
SHA-256 checksum to a GitHub release, and uses the matching `CHANGELOG.md`
section as the release notes.

Tags have the `ltr-` prefix because LTR restarted its versions at 1.0.0, and the
original StillCore already has tags `v1.0.0`…`v2.0.0`.


## Steps

1. Set the version. Change every `MARKETING_VERSION` in
   `StillCore.xcodeproj/project.pbxproj` to the new version:

   ```sh
   sed -i '' -E 's/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = 1.2.0;/' \
       StillCore.xcodeproj/project.pbxproj
   ```

2. Add a `## [1.2.0] - YYYY-MM-DD` section to `CHANGELOG.md`.
3. Commit, then tag and push:

   ```sh
   git tag -a ltr-v1.2.0 -m "StillCore LTR 1.2.0"
   git push origin main ltr-v1.2.0
   ```

4. Watch the run: `gh run watch` or the **Actions** tab.

The workflow stops before building if the tag version is not equal to
`MARKETING_VERSION`, or if `CHANGELOG.md` has no section for it.

To publish again for an existing tag (for example, after you add signing
secrets), run the workflow manually: **Actions → Release → Run workflow**, and
enter the tag. This replaces the DMG on the existing release.


## Signing and notarization

Without secrets the workflow publishes an **ad-hoc signed** DMG (`make dmg ADHOC=1`).
macOS quarantines it, so the release notes tell users to run
`xattr -dr com.apple.quarantine /Applications/StillCoreLTR.app`.

To publish a notarized DMG (`make release`), add these repository secrets in
**Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12 \| pbcopy`: a "Developer ID Application" certificate with its private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password of the `.p12` |
| `DEVELOPMENT_TEAM` | Apple team id |
| `NOTARY_APPLE_ID` | Apple ID for `notarytool` |
| `NOTARY_PASSWORD` | App-specific password for that Apple ID |

The workflow uses notarization when `MACOS_CERTIFICATE_P12`, `DEVELOPMENT_TEAM`
and `NOTARY_APPLE_ID` are all set.


## Releasing from a Mac

The same result without CI, on a Mac with Xcode:

```sh
make release DEVELOPMENT_TEAM=<team id>     # or: make dmg (ad-hoc)
shasum -a 256 StillCoreLTR.dmg > StillCoreLTR.dmg.sha256
gh release create ltr-v1.2.0 StillCoreLTR.dmg StillCoreLTR.dmg.sha256 \
    --title "StillCore LTR 1.2.0" --notes-file <(awk '/^## \[1.2.0\]/{f=1;next} f&&/^## \[/{exit} f' CHANGELOG.md)
```
