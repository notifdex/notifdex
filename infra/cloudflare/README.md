# Notifdex Cloudflare Infrastructure (`infra/cloudflare`)

Version-controlled Cloudflare configuration for `notifdex.com`, managed with **OpenTofu** and the official `cloudflare/cloudflare` v5 provider.

## Tooling & version decisions

| Component | Decision |
| --- | --- |
| IaC engine | **OpenTofu** `1.13.9` (`.opentofu-version`; `required_version = ">= 1.10.0, < 2.0.0"`) to match Inference Exchange and use native S3 lockfiles (`use_lockfile = true`). |
| Provider | `cloudflare/cloudflare` `~> 5.29.0`, with multi-platform dependency hashes committed in `.terraform.lock.hcl` (`linux_amd64`, `darwin_arm64`, `darwin_amd64`). |
| Hosting | **Cloudflare Pages** with Git integration (`website/` root, `npm run build` → `dist`, `website/**` watch path). Static hosting is \$0 on Cloudflare's free and Workers Paid plans. |
| Remote state | Dedicated private **Cloudflare R2** bucket (`notifdex-tfstate`), separate from Inference Exchange state (`ie-tfstate`), with R2 S3 conditional-write locking (`use_lockfile = true`). |

## Domain & DNS inventory (baseline verified before launch)

| Item | Verified baseline |
| --- | --- |
| Canonical apex domain | `notifdex.com` |
| Alternate typo domain (`nofidex.com`) | Not registered / no nameservers — no alternate-domain redirect configured |
| Authoritative nameservers | `angela.ns.cloudflare.com`, `jermaine.ns.cloudflare.com` (already delegated to Cloudflare) |
| Pre-existing DNS records (`A`, `AAAA`, `TXT`, `MX`) | None (clean zone; no mail records to preserve) |
| Pages production hostname | `notifdex.pages.dev` (marked `X-Robots-Tag: noindex, nofollow` via `website/src/_headers`) |
| Pages preview hostnames | `*.notifdex.pages.dev` (auto `X-Robots-Tag: noindex` by Cloudflare Pages + reinforced in `website/src/_headers`) |

## Ownership boundaries (OpenTofu vs. manual bootstrap)

Each Cloudflare setting has **one owner** to prevent drift and duplicate management:

| Resource / setting | Owner | Notes |
| --- | --- | --- |
| Domain registrar & Cloudflare zone creation | Manual (Cloudflare Dashboard) | Zone `notifdex.com` already exists and is delegated to Cloudflare. |
| R2 state bucket (`notifdex-tfstate`) & R2 S3 credentials | Manual bootstrap (one-time) | Kept outside OpenTofu state so state does not manage itself. |
| Cloudflare Pages GitHub App OAuth authorization | Manual bootstrap (one-time) | Required once in **Workers & Pages → Create → Pages → Connect to Git** (select `notifdex/notifdex`, root `website`, build `npm run build`, output `dist`, watch path `website/**`). |
| Pages project build config (`cloudflare_pages_project.website`) | OpenTofu (after import) | Import the created Pages project before enabling `apply`. Flip `manage_pages_git_source = true` only after confirming a clean no-change import plan. |
| Canonical apex custom domain (`cloudflare_pages_domain.apex`) | OpenTofu | Attaching via API/OpenTofu does **not** auto-create a DNS record. |
| Apex `CNAME` (`notifdex.com` → `notifdex.pages.dev`) | OpenTofu (`cloudflare_dns_record.apex`) | **Single-owner rule:** If you attached `notifdex.com` in the dashboard UI first, Cloudflare created an apex CNAME automatically — import it into `cloudflare_dns_record.apex` before running `tofu apply` so it is never duplicated. |
| `www` placeholder `AAAA 100::` & 301 redirect ruleset | OpenTofu (`cloudflare_dns_record.www`, `cloudflare_ruleset.canonical_redirects`) | Permanent 301 from `www.notifdex.com` → `https://notifdex.com` preserving path and query string. |
| Zone TLS settings (`ssl = strict`, `always_use_https`, `automatic_https_rewrites`, `min_tls_version = 1.2`, optional HSTS) | OpenTofu (`cloudflare_zone_setting.*`) | Leave `enable_hsts = false` until certificate issuance and redirects are verified externally. |
| Optional account-level Bulk Redirect (`notifdex.pages.dev` → `https://notifdex.com`) | Manual (optional) | Not required for SEO because `website/src/_headers` sets `X-Robots-Tag: noindex, nofollow` on `notifdex.pages.dev`. Keep any account-level Bulk Redirect scoped tightly so Inference Exchange hostnames are unaffected. |
| Optional Cloudflare Access policy on preview URLs | Manual (optional) | Public PR previews are fine for this open-source marketing site; enable Access under **Pages → Settings → General → Access policy** if private previews are ever needed. |
| Optional paid add-ons (Cloudflare Stream, Email Routing / Email Service) | Out of scope at launch | Not enabled. Launch uses static screenshots/interactive preview and GitHub Issues for support. |

## 1. Bootstrap remote state in Cloudflare R2

1. In Cloudflare Dashboard → **R2 Object Storage**, create a private bucket named `notifdex-tfstate` (no public access / no custom domain).
2. Create an R2 API token scoped **only** to `notifdex-tfstate` with **Object Read & Write** permissions. Record the Access Key ID and Secret Access Key in your password manager and GitHub Environment secrets (never commit them).
3. Copy `backend.hcl.example` to `backend.hcl` (gitignored) and set your real `<CLOUDFLARE_ACCOUNT_ID>`.
4. Initialize OpenTofu:

```bash
cd infra/cloudflare
export AWS_ACCESS_KEY_ID="<r2-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<r2-secret-access-key>"
tofu init -backend-config=backend.hcl
```

### Verify R2 state locking & recovery (required before relying on R2)

OpenTofu >= 1.10 uses `use_lockfile = true` to create `cloudflare/terraform.tfstate.tflock` via S3 conditional writes (`If-None-Match: *`). Before relying on this backend:

1. **Test concurrent lock rejection:** Run two plans simultaneously from two terminals (`tofu plan -lock-timeout=0s` while another plan/apply holds the lock, or inspect the `.tflock` object during a pause). Confirm the second process fails with a lock acquisition / `412 Precondition Failed` error rather than overwriting state.
2. **Test state backup & recovery:**
   - Download a versioned snapshot before major changes: `tofu state pull > /tmp/notifdex-state-backup.json` (store securely, delete from `/tmp` afterward).
   - Enable **R2 Object Lifecycle / periodic encrypted backup** or copy snapshots prior to state surgery; if a crashed run leaves a stale lock, verify no CI job is running and release it with `tofu force-unlock <LOCK_ID>`.
   - If the concurrent locking test ever fails against a future OpenTofu/R2 change, switch `backend.tf` to an S3-compatible backend with verified locking before running unattended applies.

## 2. Scoped Cloudflare API tokens

Never use Global API Keys or Inference Exchange tokens. Create **two** scoped Cloudflare API tokens:

1. **`notifdex-tofu-plan` (read-only — used for PR/manual plan checks):**
   - Account (`Qzyu999`): `Cloudflare Pages: Read`
   - Zone (`notifdex.com` ONLY): `Zone: Read`, `Zone Settings: Read`, `DNS: Read`, `Dynamic URL Redirects: Read` (shown as `Single Redirect: Read` in some dashboard views)
2. **`notifdex-tofu-apply` (read/write — restricted to the protected GitHub `cloudflare-prod` environment):**
   - Account (`Qzyu999`): `Cloudflare Pages: Edit`
   - Zone (`notifdex.com` ONLY): `Zone: Read`, `Zone Settings: Edit`, `DNS: Edit`, `Dynamic URL Redirects: Edit` (shown as `Single Redirect: Edit` in some dashboard views)

### Token rotation

1. Create a new scoped token with the exact same permissions.
2. Update the GitHub secret (`CLOUDFLARE_PLAN_API_TOKEN` or `CLOUDFLARE_APPLY_API_TOKEN`) and verify with a manual **Plan** run in GitHub Actions.
3. Revoke the previous token in Cloudflare Dashboard → **My Profile → API Tokens**.

## 3. First-time bootstrap & import (no-change baseline)

Follow this order so existing live resources are adopted cleanly without recreation:

1. Connect the repo once in **Workers & Pages → Create → Pages → Connect to Git**:
   - Repository: `notifdex/notifdex`, production branch: `main`
   - Root directory: `website`, build command: `npm run build`, output directory: `dist`
   - Build watch paths: include `website/**` (so Swift-only PRs do not trigger Pages builds)
   - Project name: `notifdex`
2. Import any resources that already exist in Cloudflare (Pages project, zone settings, and any dashboard-created apex CNAME or redirect ruleset):

```bash
cd infra/cloudflare
export CLOUDFLARE_API_TOKEN="<apply-or-scoped-token>"
export TF_VAR_cloudflare_account_id="<32-hex-account-id>"
export TF_VAR_zone_id="<32-hex-zone-id>"

# Import the Pages project created via Git integration
tofu import cloudflare_pages_project.website "<account_id>/notifdex"

# Import existing zone settings (zone settings always exist on an active zone)
tofu import cloudflare_zone_setting.ssl "<zone_id>/ssl"
tofu import cloudflare_zone_setting.always_use_https "<zone_id>/always_use_https"
tofu import cloudflare_zone_setting.automatic_https_rewrites "<zone_id>/automatic_https_rewrites"
tofu import cloudflare_zone_setting.min_tls_version "<zone_id>/min_tls_version"

# Only if you already added notifdex.com in the Pages dashboard UI:
# tofu import cloudflare_pages_domain.apex "<account_id>/notifdex/notifdex.com"
# tofu import cloudflare_dns_record.apex "<zone_id>/<existing_apex_dns_record_id>"
```

3. Run `tofu plan` and confirm **no unintended destruction or duplicate DNS record**.
4. Apply the reviewed plan, then re-run `tofu plan` and confirm **`No changes. Your infrastructure matches the configuration.`**
5. Once live HTTPS and redirects pass all external checks below, verify a small reversible change (for example toggling `comment` on `cloudflare_dns_record.www` or `enable_hsts`), apply via the manual `main` workflow, verify, and roll it back through a PR + reviewed plan.

## 4. GitHub Actions CI & protected apply workflow

Infrastructure workflows live in [`.github/workflows/cloudflare-infra.yml`](../../.github/workflows/cloudflare-infra.yml) and are completely separate from website content deployments:

- **Pull Requests (unprivileged):** runs `tofu fmt -check`, `tofu init -backend=false`, and `tofu validate` with zero cloud credentials.
- **Manual Plan (`workflow_dispatch`, action=`plan`):** runs from `main` using the read-only `CLOUDFLARE_PLAN_API_TOKEN` + R2 backend config; serializes runs via `concurrency: group: cloudflare-infra`.
- **Manual Apply (`workflow_dispatch`, action=`apply`, `main` only):** requires the protected GitHub Environment `cloudflare-prod` (configure Required Reviewers + `main`-only deployment branch rule in GitHub Settings → Environments), re-plans for the exact commit SHA, and applies using `CLOUDFLARE_APPLY_API_TOKEN`.

### Required GitHub configuration for authenticated Plan / Apply

- **Repository/Environment Variables:**
  - `CLOUDFLARE_ACCOUNT_ID`
  - `CLOUDFLARE_ZONE_ID`
  - `TF_STATE_R2_BUCKET` (e.g. `notifdex-tfstate`)
  - `TF_STATE_R2_KEY` (e.g. `cloudflare/terraform.tfstate`)
- **Environment Secrets:**
  - `cloudflare-plan` environment: `CLOUDFLARE_PLAN_API_TOKEN`, `R2_STATE_ACCESS_KEY_ID`, `R2_STATE_SECRET_ACCESS_KEY`
  - `cloudflare-prod` environment (protected, manual approval): `CLOUDFLARE_APPLY_API_TOKEN`, `R2_STATE_ACCESS_KEY_ID`, `R2_STATE_SECRET_ACCESS_KEY`

## 5. Drift, emergency edits, and rollbacks

### Dashboard drift or emergency edits
- If an urgent fix must be made in the Cloudflare Dashboard during an incident, log the exact change in an issue immediately.
- Reconcile back into `infra/cloudflare/*.tf` as soon as possible, run a manual `plan` to confirm the HCL matches live state (zero diff), and merge via PR.

### Website content rollback
- **Fast path (seconds):** Cloudflare Dashboard → **Workers & Pages → `notifdex` → Deployments** → select the last known-good production deployment → **Rollback to this deployment**.
- **Git path:** `git revert <bad-commit>` on `main`, which triggers a fresh Pages production build.

### Infrastructure rollback
- Revert the offending commit in `infra/cloudflare/` via PR to `main`, run the manual `plan` workflow to inspect the exact diff, and apply the reviewed rollback plan through the `cloudflare-prod` environment.

## 6. External post-launch verification checklist

Run from outside any local proxy/VPN after rollout:

```bash
# 1. Canonical apex serves 200 over HTTPS with valid TLS cert and security headers
curl -sSI https://notifdex.com/ | grep -iE '^(http/|content-security-policy|x-content-type-options|x-frame-options|referrer-policy)'

# 2. HTTP redirects to HTTPS
curl -sSI http://notifdex.com/privacy.html | grep -iE '^(http/|location:)'

# 3. Permanent www -> apex redirect preserves path and query string
curl -sSI "https://www.notifdex.com/privacy.html?ref=check" | grep -iE '^(http/|location:)'
# Expected: HTTP/2 301 and location: https://notifdex.com/privacy.html?ref=check

# 4. TLS certificate validity check
echo | openssl s_client -servername notifdex.com -connect notifdex.com:443 2>/dev/null | openssl x509 -noout -subject -issuer -dates

# 5. Production pages.dev and PR preview URLs send X-Robots-Tag: noindex
curl -sSI https://notifdex.pages.dev/ | grep -i 'x-robots-tag'
curl -sSI https://<preview-hash>.notifdex.pages.dev/ | grep -i 'x-robots-tag'
```
