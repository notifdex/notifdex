# Notifdex DevOps & Operations Runbook

This runbook captures the end-to-end operational footprint for Notifdex—macOS app CI, Developer ID signing and Apple notarization, GitHub Releases, Homebrew distribution, static website hosting on Cloudflare Pages, and OpenTofu infrastructure management.

Deep-dive bootstrap instructions remain in their focused docs:
- [Signed macOS releases & Apple setup](release-signing.md)
- [Cloudflare OpenTofu infrastructure](../infra/cloudflare/README.md)
- [Public website build & headers](../website/README.md)

## 1. Operational topology

| Surface | Repository / Service | Deployment mechanism | Live target |
| --- | --- | --- | --- |
| macOS app & CLI source | `notifdex/notifdex` (`main`) | GitHub Actions `release-macos.yml` on `v*.*.*` tags | [GitHub Releases](https://github.com/notifdex/notifdex/releases) (`Notifdex-<ver>-macOS-universal.zip`) |
| Homebrew Cask tap | `notifdex/homebrew-tap` (`Casks/notifdex.rb`) | Auto-pushed by `release-macos.yml` via SSH Deploy Key | `brew install --cask notifdex/tap/notifdex` |
| Public website | `notifdex/notifdex` (`website/`) | Cloudflare Pages Git integration (`website/*` watch path) | `https://notifdex.com` (`notifdex.pages.dev` is `noindex`) |
| DNS, TLS, redirects, Pages config | `notifdex/notifdex` (`infra/cloudflare/`) | OpenTofu `1.13.9` + R2 state (`notifdex-tfstate`) via `cloudflare-infra.yml` | Cloudflare zone `notifdex.com` |

### Apple & GitHub identities

- **Apple Developer Program:** Individual enrollment, Team ID `HNH4DY9A2T` (can also sign other macOS apps under separate bundle IDs, and converts in-place to an Organization account later while preserving Team ID `HNH4DY9A2T`).
- **macOS bundle identifier:** `com.notifdex.mac` (stable across releases so macOS TCC preserves Accessibility permissions across `brew upgrade --cask notifdex`; verified in [#20](https://github.com/notifdex/notifdex/issues/20)).
- **GitHub organization:** `notifdex` (with **Deploy keys** enabled under *Organization Settings → Member privileges* so `notifdex/homebrew-tap` accepts write deploy keys).

## 2. GitHub Actions workflows

| Workflow | Trigger | Runner | Secrets / Environments | What it verifies or deploys |
| --- | --- | --- | --- | --- |
| [`checks.yml`](../.github/workflows/checks.yml) | `push`, `pull_request`, `workflow_dispatch` | `macos-26-intel`, `ubuntu-latest` | None (`contents: read`) | `swift test`, `-warnings-as-errors`, CLI flock smoke test, native & universal `.app` packaging, menu bar smoke test, TLC on all `spec/*.cfg`, all Python `contract-tests/` |
| [`website-ci.yml`](../.github/workflows/website-ci.yml) | `push` / `pull_request` touching `website/**` | `ubuntu-latest` | None (`contents: read`) | `npm run build` (SHA-256 cache-busting) and `npm run check` (links, canonicals, strict CSP, `#theme-toggle`, branding, `_headers`, `sitemap.xml`) |
| [`release-macos.yml`](../.github/workflows/release-macos.yml) | Tag push `v*.*.*`, `workflow_dispatch` | `macos-26-intel` | Repo secrets (Apple + Deploy Key) | `swift test`, hardened-runtime Developer ID universal build (`arm64` + `x86_64`), designated-requirement check (`com.notifdex.mac` + `HNH4DY9A2T`), smoke test, `notarytool submit --wait`, `stapler staple/validate`, `spctl --assess`, GitHub Release upload, `notifdex/homebrew-tap` push, ephemeral keychain/SSH cleanup |
| [`cloudflare-infra.yml`](../.github/workflows/cloudflare-infra.yml) | PR (`infra/cloudflare/**`) + manual `workflow_dispatch` | `ubuntu-latest` | PR: none; `plan`: `cloudflare-plan`; `apply`: protected `cloudflare-prod` | PR: `tofu fmt -check` + `tofu validate`; manual `plan` / guarded `apply` on `main` with `confirm_commit` |

> **GitHub Actions rule to remember:** Never reference `secrets.*` inside a step or job `if:` expression—GitHub rejects the workflow at parse time (guarded by `contract-tests/test_release_and_homebrew_contract.py`). Pass secrets through `env:` and check non-emptiness in bash.

## 3. Secrets & credentials inventory

Never commit `.p12`, `.p8`, `.cer`, `.certSigningRequest`, `backend.hcl`, `*.tfvars`, or `*.tfstate` files (enforced by `.gitignore` and contract tests).

| Secret / Credential | Scope | Expiration | Password-manager backup? | Purpose |
| --- | --- | --- | --- | --- |
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | `notifdex/notifdex` repo secret | Cert expires ~5 years | **Yes** (reusable across other macOS apps) | Base64-encoded Developer ID Application `.p12` |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | `notifdex/notifdex` repo secret | Matches `.p12` | **Yes** | Export password for the `.p12` |
| `APPLE_TEAM_ID` | `notifdex/notifdex` repo secret | Permanent (`HNH4DY9A2T`) | Note only | Team ID verified against codesign designated requirement |
| `APPLE_NOTARY_KEY_P8_BASE64` | `notifdex/notifdex` repo secret | Does not auto-expire | **Yes** (Apple only allows 1 download) | App Store Connect Team API Key (`.p8`, Developer role) |
| `APPLE_NOTARY_KEY_ID` | `notifdex/notifdex` repo secret | Permanent (`8NM2DVP5V7`) | Note only (visible in ASC) | Key ID for `xcrun notarytool` |
| `APPLE_NOTARY_ISSUER_ID` | `notifdex/notifdex` repo secret | Permanent | Note only (visible in ASC) | Team Issuer UUID for `xcrun notarytool` |
| `HOMEBREW_TAP_DEPLOY_KEY` | `notifdex/notifdex` repo secret + public key on `notifdex/homebrew-tap` Deploy Keys (write enabled) | **Never expires** | No (regenerate in 20s) | Pushes `Casks/notifdex.rb` to `notifdex/homebrew-tap` |
| `CLOUDFLARE_PLAN_API_TOKEN` | `cloudflare-plan` env secret | Per token policy | Rotate via Cloudflare Dashboard | Read-only OpenTofu plans on `notifdex.com` |
| `CLOUDFLARE_APPLY_API_TOKEN` | `cloudflare-prod` env secret (protected) | Per token policy | Rotate via Cloudflare Dashboard | Scoped read/write OpenTofu applies on `notifdex.com` |
| `R2_STATE_ACCESS_KEY_ID` / `R2_STATE_SECRET_ACCESS_KEY` | `cloudflare-plan` & `cloudflare-prod` env secrets | Per R2 token | Yes | S3-compatible R2 state (`notifdex-tfstate`) + lockfile |

## 4. Standard operating procedures

### A. Cut a new macOS release (`vX.Y.Z`)

1. Ensure all target PRs are merged on `main` and `Foundation checks` is green.
2. *(Recommended)* Add a short plain-English release entry to [`website/src/updates.html`](../website/src/updates.html) in a PR (or follow-up PR right after tagging).
3. Tag and push from clean `main`:
   ```bash
   git checkout main && git pull --ff-only
   git tag v0.1.4
   git push origin v0.1.4
   ```
4. Watch `Release macOS app` in GitHub Actions (~5–9 minutes). Confirm:
   - GitHub Release `v0.1.4` has `Notifdex-0.1.4-macOS-universal.zip`, `.sha256`, and `notifdex.rb`.
   - `notifdex/homebrew-tap` has a new `github-actions[bot]` commit `notifdex 0.1.4` updating `Casks/notifdex.rb`.
5. Smoke-test on a Mac:
   ```bash
   brew update && brew upgrade --cask notifdex
   open /Applications/Notifdex.app
   ```
   Confirm existing Inbox data loads and a fresh alert captures without re-granting Accessibility.

### B. Deploy or roll back `notifdex.com`

- **Normal deploy:** Merge a PR touching `website/` to `main`. Cloudflare Pages watches `website/*`, runs `npm run build` inside `website/`, appends SHA-256 `?v=<hash>` query strings to `styles.css` and `app.js` to bust browser/CDN caches, and serves `website/dist/`.
- **Local preview before merging:**
  ```bash
  npm --prefix website run build && npm --prefix website run check && npm --prefix website run preview
  # Open http://127.0.0.1:4173
  ```
- **Fast rollback (seconds):** Cloudflare Dashboard → **Workers & Pages → `notifdex` → Deployments** → choose the previous good deployment → **Rollback to this deployment**. Follow with `git revert` on `main`.

### C. Roll back a bad macOS release or Homebrew Cask

1. **Immediate Homebrew rollback:** Revert the latest commit in `notifdex/homebrew-tap` (`Casks/notifdex.rb` back to the prior known-good version and SHA-256) and push to `main`.
2. **GitHub Release:** Mark the bad release as a draft or delete its faulty assets so direct downloaders get the prior release on `/releases/latest`.
3. **Fix forward:** Land the fix on `main` and cut the next patch tag (never reuse a published version number once Homebrew users have downloaded it).

### D. Change Cloudflare infrastructure (`infra/cloudflare/`)

1. Edit `infra/cloudflare/*.tf` on a branch and open a PR (`cloudflare-infra.yml` validates formatting and schema without credentials).
2. Merge to `main`, run **Actions → Cloudflare Infra → Run workflow (`action=plan`)**, and review the diff.
3. Run **Run workflow (`action=apply`, `confirm_commit=<sha>`)** and approve the `cloudflare-prod` environment gate.
4. Keep `path_includes = ["website/*"]` (single `*` matches across `/`; `website/**` silently skips Cloudflare Pages builds).

### E. Rotate credentials

- **Homebrew tap Deploy Key:** Delete the old key on `notifdex/homebrew-tap` → Settings → Deploy keys, then run:
  ```bash
  ssh-keygen -t ed25519 -N "" -C "notifdex-release-bot" -f /tmp/notifdex-tap-key
  gh repo deploy-key add /tmp/notifdex-tap-key.pub --repo notifdex/homebrew-tap --title notifdex-release-bot --allow-write
  gh secret set HOMEBREW_TAP_DEPLOY_KEY --repo notifdex/notifdex < /tmp/notifdex-tap-key
  rm -f /tmp/notifdex-tap-key /tmp/notifdex-tap-key.pub
  ```
- **Apple Developer ID `.p12` / Notary `.p8`:** Follow [docs/release-signing.md](release-signing.md) and update the corresponding `APPLE_*` repository secrets in `notifdex/notifdex`.
- **Cloudflare API / R2 tokens:** Follow [infra/cloudflare/README.md](../infra/cloudflare/README.md#token-rotation) and verify with a manual `plan` run before revoking the old token.
