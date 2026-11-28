# Setup in detail

## Private App

The private build keeps the upstream Python code, runtime and native helpers in `LocalVoice.app`. It does not install a Homebrew formula, patch another app, or write a LaunchAgent. To build it:

1. Use [`scripts/build-runtime.sh --help`](../scripts/build-runtime.sh) to prepare the relocatable ARM64 runtime archive from local, checksum-pinned inputs. `--check-inputs` checks the archives, wheel lock and license inputs without executing the runtime.
2. Build the [NVIDIA Core ML worker](development-checks.md#nvidia-providers) with `scripts/build-parakeet.sh`. Pass its executable and license to `scripts/build-app.sh`, along with the produced runtime archive and digest, the pinned ctrlSPEAK source archive and a deployment target.
3. Run `scripts/build-app.sh --verify /path/to/LocalVoice.app` on the staged bundle. Signing, notarization and a run on the oldest supported macOS are separate release checks.

The build commands do not fetch inputs.

The app exposes these actions in its menu:

| Action | What it does |
|---|---|
| **Settings…** | One window with a sidebar: **General** (menu bar icon, launch at login), **Dictation** (shortcuts, microphone, vocabulary), **Recording** (live preview, microphone standby, media pause, sounds) and **Models**. Vocabulary is greyed out while the model in use ignores it. |
| **Models…** | Opens Settings at **Models**: model source and size, and the language choice for each model that accepts one. Downloads are explicit. Existing verified Hugging Face snapshots are reused in place; only LocalVoice-owned copies can be removed. **Use** starts the new model and leaves the previous selection intact if loading fails. |
| **Permissions…** | Shows Microphone, Accessibility and Input Monitoring as numbered steps that update live. Reads **Finish Setup…** while something is missing. |
| **Launch at Login** | Registers the app with macOS only if enabled. |
| **Check for Updates…** | Release and dev builds only: looks for a new version now. A found update replaces this item with **Update to LocalVoice x.y.z…** at the top of the menu and puts a dot on the icon. See [In-app updates](#in-app-updates). |

The app keeps owned models in `~/Library/Application Support/LocalVoice/Models`. It does not write dictated text to logs or to an existing ctrlSPEAK history database. To uninstall, turn off **Launch at Login**, quit, and move the app to Trash. Model files and preferences are not removed with the app.

If access is missing, the window opens without requesting anything and updates live. The next step is highlighted and holds the default button; the others stay clickable. For Accessibility and Input Monitoring, **Open Settings…** opens the list and a guide panel: drag the app icon in and switch it on; the panel confirms and offers the next step without leaving System Settings. If macOS offers **Quit & Reopen**, choose it; LocalVoice also offers **Reopen** when Input Monitoring is on but not yet in effect, and resumes on the finished window. When the first model is ready after setup, a short screen shows the hotkey gesture and where Settings are. Test builds are a new identity after every rebuild: rows granted to an earlier build show **Old entry**, and **Re-add…** removes that entry (`tccutil reset`) before adding the app again.

## Local Test App

On Apple Silicon with macOS 15+, Command Line Tools and Python 3.11:

```sh
python3 -B scripts/build-dev-app.py
open build/dev/LocalVoice.app
```

The build downloads development dependencies and pinned upstream source, not model weights. It uses an isolated virtual environment and ad-hoc signing; no Developer ID or Homebrew installer is needed. Keep the app and `build/dev/venv` where the build put them. Add `--worker /path/to/localvoice-parakeet` to reuse an existing worker. This is a local test build, not a redistributable app.

Add `--portable` to embed a pinned standalone CPython (python-build-standalone) in the app instead of referencing `build/dev/venv`. The bundle can then be moved, zipped and run on another Apple Silicon Mac. `--version` and `--build-number` set the bundle version. Python dependencies other than `mlx-whisper` are not pinned, so two portable builds can differ.

## Releases and Dev Releases

Every push to `main` (every merged PR) runs [`.github/workflows/build.yml`](../.github/workflows/build.yml) on a GitHub-hosted Apple Silicon runner: `scripts/check.sh`, then a `--portable` build that is signed with the Developer ID ([`scripts/sign-app.py`](../scripts/sign-app.py)) and packed into a signed disk image, which Apple notarizes ([`scripts/notarize-app.sh`](../scripts/notarize-app.sh)); it is published as a pre-release tagged `v<VERSION>-dev.<run>`. The last ten dev releases are kept. Changes that only touch `site/`, `docs/` or Markdown files don't trigger a build. It can also be started manually from the Actions tab.

To install a dev release:

1. Download `LocalVoice-v…-dev.N-arm64.dmg` from [Releases](https://github.com/Schereo/localvoice/releases) and open it.
2. Drag `LocalVoice.app` onto the **Applications** link (or anywhere else you like).
3. Open the app and follow **Permissions…**. Signed builds keep their permissions across updates; rows from an older unsigned dev build show **Old entry**, use **Re-add…** once.

Dev releases up to `v1.2.0-dev.5` were ad-hoc signed and need `xattr -dr com.apple.quarantine /Applications/LocalVoice.app` before the first launch.

### Signing secrets

The signing job runs in the `release` environment (Settings → Environments), which only `main` and release tags (`vX.Y.Z`, not the `-dev.N` tags) may use. Two repository rulesets guard those refs: changes reach `main` only through a pull request with one approval, and only admins can create, move or delete release tags. Admins can bypass both, so `scripts/release.sh` can still push the release commit and tag. The environment needs these secrets:

| Secret | Content |
| --- | --- |
| `MACOS_CERT_P12` | Developer ID Application certificate with its private key, as base64-encoded `.p12` |
| `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| `APPLE_API_KEY_P8` | App Store Connect API key (Team key, role Developer), the `.p8` file's content |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | The issuer ID shown above the key list in App Store Connect |
| `HOMEBREW_TAP_DEPLOY_KEY` | Private half of an SSH deploy key with write access to [Schereo/homebrew-tap](https://github.com/Schereo/homebrew-tap) (its Settings → Deploy keys) |
| `SPARKLE_ED_PRIVATE_KEY` | Private half of the EdDSA (ed25519) key that signs update archives and delta patches: the 32-byte seed in base64, as `generate_appcast --ed-key-file` reads it. See [In-app updates](#in-app-updates). |

The `build` job runs the checks and the build without any secrets and hands the unsigned app on as an artifact. Only the `sign` job, on a fresh runner that runs no build code, uses the environment: it imports the certificate into a throwaway keychain, signs every Mach-O file of the bundle with the hardened runtime, wraps the app in a disk image with an **Applications** link and signs that too, notarizes the image once (the ticket covers the app inside) and staples it, and removes the certificate before publishing. A tag build stops unless the tagged commit is on `main`. Entitlements are in [`scripts/entitlements/`](../scripts/entitlements/). Both scripts also run locally with a Developer ID in the login keychain.

Dev releases use the bundle identifier `com.localvoice.dev` and the name **LocalVoice Test**, the same as local test builds, so they install next to a release.

A release is cut with `./scripts/release.sh <version>` (it moves the Unreleased changelog section under the version and tags `v<version>`). Pushing the tag runs the same workflow, which builds **LocalVoice** with the bundle identifier `com.localvoice.app`, signs and notarizes it, and publishes the GitHub release `v<version>` with `LocalVoice-v<version>-arm64.dmg` and the changelog section as notes. The tag must match `VERSION`. Once the release is published, the workflow starts the website deploy ([`.github/workflows/cloudflare-workers.yml`](../.github/workflows/cloudflare-workers.yml)), which points the download button and its version label at the latest published release ([`scripts/stamp-site-release.py`](../scripts/stamp-site-release.py)); pre-releases are skipped. The link in `site/index.html` therefore never needs a manual bump; the committed page keeps the version it was written with.

After the release is published, the `homebrew` job moves the cask in [Schereo/homebrew-tap](https://github.com/Schereo/homebrew-tap) (`Casks/localvoice.rb`) to the new version and checksum and pushes it with the deploy key, so `brew install --cask schereo/tap/localvoice` and `brew upgrade` get the release within minutes. Dev releases don't touch the cask. If the job fails, the release itself is fine: re-run the job, or edit `version` and `sha256` in the cask by hand (the checksum is in the release's `.sha256` file).

### In-app updates

Release and dev builds update themselves with [Sparkle](https://sparkle-project.org) (pinned and checksum-verified by [`scripts/fetch-sparkle.sh`](../scripts/fetch-sparkle.sh); the app code is [`src/localvoice-updater.swift`](../src/localvoice-updater.swift)).

- **In the app.** The updater starts once setup is done (permissions granted, a model chosen). From then on it looks for an update once a day (`SUEnableAutomaticChecks` is on, so Sparkle asks nothing first); the switch under **Settings › General › Updates** turns that off. Before setup is done, LocalVoice contacts no update server. A found update does not open a window: the menu bar icon gets a dot, the menu leads with **Update to LocalVoice x.y.z…**, and **Settings › General › Updates** offers the same button next to the switch for automatic checks. With the menu bar icon hidden, Sparkle shows the update in its own window instead. Installing quits LocalVoice (and its service), replaces the app in place and reopens it; permissions, models and settings stay, because the bundle identifier and the Developer ID stay the same.
- **The feed.** `build-dev-app.py --feed-url` writes `SUFeedURL` and `SUPublicEDKey` into `Info.plist`; builds without it (local test builds, the private app) have no updater. Releases read `releases/latest/download/appcast.xml`, so each new release takes over as soon as it is published. Dev builds read `releases/download/dev-feed/appcast.xml` from the fixed `dev-feed` pre-release, which every dev build replaces; GitHub's latest link skips pre-releases. Don't delete `dev-feed`.
- **Delta patches.** After notarization, and after the certificate is gone, the `sign` job runs [`scripts/make-appcast.py`](../scripts/make-appcast.py). It downloads the disk images of the last two builds of the same channel that already have the updater (those with an `appcast.xml` asset), and Sparkle's `generate_appcast` writes the feed and one patch per earlier build (`LocalVoice<new>-<old>.delta`). Most of the 1.4-GB app (the Python runtime) does not change between builds, so a patch is a few MB instead of the 540-MB image. Before applying a patch, Sparkle checks that the installed app is exactly the published one; a copy that was changed, or is more than two builds behind, downloads the full image. The patches and the feed are attached to the release. Making two patches takes a few minutes and up to about 8 GB of memory on the runner.
- **Build numbers.** Sparkle offers a build only if its `CFBundleVersion` is higher than the installed one. CI sets it to the number of commits on `main` (`git rev-list --count HEAD`), which only grows; the run number restarts whenever the workflow does. Dev builds share their short version (`1.4.0`), so the menu shows the build number with it.
- **The key.** Sparkle accepts an update only if the archive or patch is signed with the EdDSA key whose public half is in the installed app (`SPARKLE_PUBLIC_KEY` in [`scripts/build-dev-app.py`](../scripts/build-dev-app.py)), and only if the new app carries the same Developer ID. The private half is the `SPARKLE_ED_PRIVATE_KEY` secret. Keep a copy of it outside GitHub: without it, no installed copy accepts another update, and everyone has to download the next version by hand. A new key can only be introduced through a release signed with the old one.
- **Locally.** `make-appcast.py --base <earlier.dmg> --url-prefix http://127.0.0.1:8000/` builds a feed and patches from local images, without GitHub, for a dry run against a local web server.

The first release with the updater still has to be installed by hand once; from then on it updates itself.

## Coming from the old Homebrew installer

Versions before 1.5 could also be installed from source with `./install.sh --legacy-homebrew`, which patched a Homebrew copy of ctrlSPEAK and ran it as a LaunchAgent. That installer is gone. To switch to the app:

Quit the old LocalVoice first if you opened it by hand, then:

```bash
launchctl bootout "gui/$(id -u)/com.localvoice.app" 2>/dev/null
launchctl bootout "gui/$(id -u)/com.localvoice.ctrlspeak" 2>/dev/null
rm -f ~/Library/LaunchAgents/com.localvoice.app.plist ~/Library/LaunchAgents/com.localvoice.ctrlspeak.plist
rm -rf ~/Applications/LocalVoice.app ~/Applications/ctrlSPEAK.app
rm -f "$(brew --prefix)/bin/ctrlspeak-overlay" "$(brew --prefix)/bin/ctrlspeak-local"
brew uninstall ctrlspeak   # or: brew reinstall ctrlspeak, to keep an unpatched ctrlSPEAK
tccutil reset All com.localvoice.app
```

Then install the app (see the [README](../README.md)). `~/.config/localvoice/config` is kept and read by the app; the Hugging Face model cache is reused. The app chooses the dictation language per model, so a forced `language = en` from the old install does not carry over: pick it again under **Settings › Models**.
