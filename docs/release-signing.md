# Signed macOS releases and Homebrew distribution

Notifdex publishes Developer ID–signed, Apple-notarized universal macOS builds (`arm64` + `x86_64`) via GitHub Actions on GitHub Releases, and distributes them through the [`notifdex/homebrew-tap`](https://github.com/notifdex/homebrew-tap) Homebrew Cask.

Every signed release uses the same bundle identifier (`com.notifdex.mac`), the same Apple Developer Team ID (`HNH4DY9A2T`), and a strictly monotonic `CFBundleVersion` so macOS preserves Accessibility access across `brew upgrade --cask notifdex` updates (see [#20](https://github.com/notifdex/notifdex/issues/20)).

## One-time setup (about 10 minutes)

You only need two credentials from Apple and one token for the Homebrew tap repo. Never commit `.p12`, `.p8`, or certificate files to Git.

### 1. Create a Developer ID Application certificate (`.p12`)

1. Open **Keychain Access** on your Mac → menu bar **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority…**
2. Enter your email, choose **Saved to disk**, and save `CertificateSigningRequest.certSigningRequest`.
3. Open [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list) and click **+**.
4. Choose **Developer ID Application** (under *Software*, for distributing outside the Mac App Store), click **Continue**, upload your CSR file, and download the resulting `.cer` file.
5. Double-click the downloaded `.cer` file to install it into your Mac's **login** keychain.
6. In **Keychain Access → My Certificates**, find **`Developer ID Application: … (HNH4DY9A2T)`**, right-click it → **Export…**, save as `developer-id.p12`, and protect it with a strong export password.
7. Base64-encode it to copy into GitHub Secrets (then delete the temporary `.p12` file if you don't need it on disk):

```bash
base64 -i developer-id.p12 | pbcopy
```

### 2. Create an App Store Connect API key (`.p8`) for notarization

1. Open [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) (Team Keys).
2. Click **+** (Generate API Key), give it a name like `Notifdex Notarization`, select **Developer** (or **App Manager**), and click **Generate**.
3. Note the **Issuer ID** (at the top of the page) and the new key's **Key ID**.
4. Click **Download** to save `AuthKey_<KEY_ID>.p8` (Apple only lets you download it once—store it safely in your password manager).
5. Base64-encode it for GitHub Secrets:

```bash
base64 -i AuthKey_<KEY_ID>.p8 | pbcopy
```

### 3. Create a never-expiring Deploy Key for `notifdex/homebrew-tap`

Instead of an expiring PAT, use a single SSH Deploy Key scoped exclusively to `notifdex/homebrew-tap` (ensure **Deploy keys** are enabled under `notifdex` Organization Settings → Member privileges):

```bash
ssh-keygen -t ed25519 -N "" -C "notifdex-release-bot" -f /tmp/notifdex-tap-key
gh repo deploy-key add /tmp/notifdex-tap-key.pub --repo notifdex/homebrew-tap --title notifdex-release-bot --allow-write
gh secret set HOMEBREW_TAP_DEPLOY_KEY --repo notifdex/notifdex < /tmp/notifdex-tap-key
rm -f /tmp/notifdex-tap-key /tmp/notifdex-tap-key.pub
```

### 4. Create a Developer ID provisioning profile for macOS CloudKit sync *(required for iCloud Sync in Homebrew releases)*

macOS Developer ID apps require an embedded **Developer ID Application** provisioning profile to access the shared **Production** CloudKit container (`iCloud.com.notifdex.shared`):

1. Deploy the `iCloud.com.notifdex.shared` schema from **Development → Production** in [CloudKit Console](https://icloud.developer.apple.com/dashboard) (Production CloudKit does not auto-create schema on write).
2. In [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list), open **`com.notifdex.mac`** (macOS), ensure **iCloud** (`CloudKit`, container `iCloud.com.notifdex.shared`) is enabled (and optionally **Push Notifications** for silent CloudKit wake).
3. In [Apple Developer → Profiles](https://developer.apple.com/account/resources/profiles/list), click **+** → **Distribution → Developer ID** → select **`com.notifdex.mac`** → select **`Developer ID Application: … (HNH4DY9A2T)`** → name it `Notifdex macOS Developer ID CloudKit` → **Download** `.provisionprofile`.
4. Base64-encode the profile and store it as `APPLE_MAC_CLOUDKIT_PROFILE_BASE64`:

```bash
base64 -i Notifdex_macOS_Developer_ID_CloudKit.provisionprofile | gh secret set APPLE_MAC_CLOUDKIT_PROFILE_BASE64 --repo notifdex/notifdex
```

When `APPLE_MAC_CLOUDKIT_PROFILE_BASE64` is set, [`.github/workflows/release-macos.yml`](../.github/workflows/release-macos.yml) embeds the profile, signs with [`Resources/NotifdexMacRelease.entitlements`](../Resources/NotifdexMacRelease.entitlements) (`Production` CloudKit environment, plus `aps-environment` automatically when granted by the profile), verifies the entitlements and launch via `tools/smoke-app.sh`, and cleans up the temporary profile in `if: always()`.

### 5. Add GitHub Actions secrets in `notifdex/notifdex`

In **GitHub → `notifdex/notifdex` → Settings → Secrets and variables → Actions → New repository secret**, add:

| Secret name | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | Base64 output of `developer-id.p12` |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Export password you set for `developer-id.p12` |
| `APPLE_TEAM_ID` | `HNH4DY9A2T` |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 output of `AuthKey_<KEY_ID>.p8` |
| `APPLE_NOTARY_KEY_ID` | The 10-character Key ID from App Store Connect |
| `APPLE_NOTARY_ISSUER_ID` | The UUID Issuer ID from App Store Connect |
| `APPLE_MAC_CLOUDKIT_PROFILE_BASE64` *(recommended)* | Base64 output of the Developer ID `.provisionprofile` for `com.notifdex.mac` (`iCloud.com.notifdex.shared`) |
| `HOMEBREW_TAP_DEPLOY_KEY` *(optional)* | Private ed25519 SSH key whose public half is a write-enabled Deploy Key on `notifdex/homebrew-tap` (never expires) |

*(You can reuse the exact same Developer ID `.p12` and App Store Connect API key secrets across other apps signed under Team ID `HNH4DY9A2T`.)*

## Cutting a release

Push a semantic version tag from `main`:

```bash
git checkout main && git pull --ff-only
git tag v0.1.0
git push origin v0.1.0
```

[`.github/workflows/release-macos.yml`](../.github/workflows/release-macos.yml) will automatically:
1. Run `swift test` and strict warning checks.
2. Build a universal `Notifdex.app` (`arm64` + `x86_64`) with hardened runtime and monotonic `CFBundleVersion`.
3. Verify the code signature and designated requirement (`com.notifdex.mac` + `HNH4DY9A2T`).
4. Submit to Apple's Notary Service, staple the ticket onto `Notifdex.app`, and verify with `spctl --assess`.
5. Publish `Notifdex-<version>-macOS-universal.zip`, its `.sha256`, and `notifdex.rb` to GitHub Releases.
6. Push the updated `Casks/notifdex.rb` to `notifdex/homebrew-tap` (when `HOMEBREW_TAP_DEPLOY_KEY` is set).

## Verifying Accessibility continuity across updates (#20)

Before opening the public Mac beta (#22), validate two sequential signed releases on a real Mac:

1. Remove any prior ad-hoc `Notifdex.app` from `~/Applications` and clear its old Accessibility entry.
2. Install the first signed release:
   ```bash
   brew install --cask notifdex/tap/notifdex
   open /Applications/Notifdex.app
   ```
3. Grant **Notifdex** Accessibility access once in **System Settings → Privacy & Security → Accessibility**, and verify a synthetic notification is captured in Inbox.
4. Cut the next release tag (e.g. `v0.1.1`) and upgrade:
   ```bash
   brew update && brew upgrade --cask notifdex
   open /Applications/Notifdex.app
   ```
5. Send a second synthetic notification and verify it captures into the **same Inbox** without re-granting Accessibility.
