locals {
  www_hostname = "www.${var.canonical_domain}"
  pages_target = "${var.pages_project_name}.pages.dev"
}

# -----------------------------------------------------------------------------
# Cloudflare Pages project & canonical custom domain
# -----------------------------------------------------------------------------
# One-time GitHub App authorization happens in the Cloudflare dashboard.
# After creating/linking the project in the dashboard (or authorizing the GitHub
# App first), import this resource into state so OpenTofu owns build config and
# project settings without replacing the project.
resource "cloudflare_pages_project" "website" {
  account_id        = var.cloudflare_account_id
  name              = var.pages_project_name
  production_branch = var.production_branch

  build_config = {
    build_command   = "npm run build"
    destination_dir = "dist"
    root_dir        = "website"
  }

  source = var.manage_pages_git_source ? {
    type = "github"
    config = {
      owner                          = var.github_owner
      repo_name                      = var.github_repo
      production_branch              = var.production_branch
      deployments_enabled            = true
      production_deployments_enabled = true
      pr_comments_enabled            = true
      preview_deployment_setting     = "all"
      path_includes                  = ["website/**"]
    }
  } : null
}

# Binds the canonical apex hostname to the Pages project and triggers Universal
# / custom-domain TLS certificate issuance.
#
# Ownership note: Creating cloudflare_pages_domain via API/OpenTofu does NOT
# automatically create the DNS CNAME record (unlike the Cloudflare dashboard UI).
# cloudflare_dns_record.apex below is therefore the sole owner of the apex CNAME.
# If the dashboard already created an apex CNAME during bootstrap, import that
# record into cloudflare_dns_record.apex before applying so it is never managed twice.
resource "cloudflare_pages_domain" "apex" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.website.name
  name         = var.canonical_domain
}

# -----------------------------------------------------------------------------
# DNS records (single owner per record)
# -----------------------------------------------------------------------------
resource "cloudflare_dns_record" "apex" {
  zone_id = var.zone_id
  name    = var.canonical_domain
  type    = "CNAME"
  content = local.pages_target
  proxied = true
  ttl     = 1
  comment = "Managed by OpenTofu (infra/cloudflare): apex custom domain for Cloudflare Pages"

  depends_on = [cloudflare_pages_domain.apex]
}

# Proxied dummy AAAA record (RFC 6666 discard prefix 100::) so requests to
# www.notifdex.com reach the Cloudflare edge and execute the zone redirect rule.
resource "cloudflare_dns_record" "www" {
  count = var.enable_www_redirect ? 1 : 0

  zone_id = var.zone_id
  name    = local.www_hostname
  type    = "AAAA"
  content = "100::"
  proxied = true
  ttl     = 1
  comment = "Managed by OpenTofu (infra/cloudflare): proxied placeholder for permanent www -> apex redirect"
}

# -----------------------------------------------------------------------------
# Permanent www -> apex redirect (preserves path and query string)
# -----------------------------------------------------------------------------
# Note: Cloudflare allows at most one zone-level ruleset per phase. If the zone
# already has an http_request_dynamic_redirect ruleset, import it into this
# resource instead of creating a second one.
resource "cloudflare_ruleset" "canonical_redirects" {
  count = var.enable_www_redirect ? 1 : 0

  zone_id     = var.zone_id
  name        = "Notifdex canonical redirects"
  description = "Permanent redirect from www.${var.canonical_domain} to https://${var.canonical_domain} preserving path and query string."
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = [
    {
      ref         = "redirect_www_to_apex"
      description = "Permanent 301 redirect from www to canonical apex"
      enabled     = true
      expression  = "(http.host eq \"${local.www_hostname}\")"
      action      = "redirect"
      action_parameters = {
        from_value = {
          status_code           = 301
          preserve_query_string = true
          target_url = {
            expression = "concat(\"https://${var.canonical_domain}\", http.request.uri.path)"
          }
        }
      }
    }
  ]
}

# -----------------------------------------------------------------------------
# Zone TLS & HTTPS settings
# -----------------------------------------------------------------------------
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = var.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "automatic_https_rewrites" {
  zone_id    = var.zone_id
  setting_id = "automatic_https_rewrites"
  value      = "on"
}

resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = var.zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "security_header" {
  count = var.enable_hsts ? 1 : 0

  zone_id    = var.zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 15552000
      include_subdomains = false
      preload            = false
      nosniff            = true
    }
  }
}
