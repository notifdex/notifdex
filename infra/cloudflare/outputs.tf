output "pages_project_name" {
  description = "Cloudflare Pages project name."
  value       = cloudflare_pages_project.website.name
}

output "pages_subdomain" {
  description = "Default Cloudflare Pages subdomain (kept noindex via website/src/_headers)."
  value       = cloudflare_pages_project.website.subdomain
}

output "canonical_url" {
  description = "Public canonical HTTPS URL for Notifdex."
  value       = "https://${var.canonical_domain}"
}

output "www_redirect_source" {
  description = "Redirected www hostname when enable_www_redirect is true."
  value       = var.enable_www_redirect ? "https://${local.www_hostname}" : null
}

output "apex_dns_record_id" {
  description = "Cloudflare DNS record ID for the apex CNAME."
  value       = cloudflare_dns_record.apex.id
}

output "www_dns_record_id" {
  description = "Cloudflare DNS record ID for the www redirect placeholder."
  value       = var.enable_www_redirect ? cloudflare_dns_record.www[0].id : null
}

output "redirect_ruleset_id" {
  description = "Cloudflare Ruleset ID for zone dynamic redirects."
  value       = var.enable_www_redirect ? cloudflare_ruleset.canonical_redirects[0].id : null
}
