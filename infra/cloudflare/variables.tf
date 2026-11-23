variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the Notifdex Pages project and zone."
  type        = string

  validation {
    condition     = can(regex("^[a-f0-9]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be a 32-character lowercase hexadecimal Cloudflare account ID."
  }
}

variable "zone_id" {
  description = "Cloudflare zone ID for the canonical domain (notifdex.com)."
  type        = string

  validation {
    condition     = can(regex("^[a-f0-9]{32}$", var.zone_id))
    error_message = "zone_id must be a 32-character lowercase hexadecimal Cloudflare zone ID."
  }
}

variable "canonical_domain" {
  description = "Canonical apex domain serving the Notifdex website."
  type        = string
  default     = "notifdex.com"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.canonical_domain)) && !startswith(var.canonical_domain, "www.")
    error_message = "canonical_domain must be a lowercase apex hostname without a www. prefix."
  }
}

variable "pages_project_name" {
  description = "Cloudflare Pages project name (also determines <name>.pages.dev)."
  type        = string
  default     = "notifdex"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,56}[a-z0-9]$", var.pages_project_name))
    error_message = "pages_project_name must be lowercase alphanumeric with hyphens."
  }
}

variable "production_branch" {
  description = "Git branch that deploys to production on Cloudflare Pages."
  type        = string
  default     = "main"
}

variable "github_owner" {
  description = "GitHub repository owner for Cloudflare Pages Git integration."
  type        = string
  default     = "notifdex"
}

variable "github_repo" {
  description = "GitHub repository name for Cloudflare Pages Git integration."
  type        = string
  default     = "notifdex"
}

variable "manage_pages_git_source" {
  description = "Whether OpenTofu manages the GitHub source block on the Pages project. Keep true after the one-time Cloudflare GitHub App OAuth connection is authorized and the project is imported so applies preserve the repo binding."
  type        = bool
  default     = true
}

variable "enable_www_redirect" {
  description = "Whether to manage the www placeholder DNS record and permanent 301 redirect to the canonical apex domain."
  type        = bool
  default     = true
}

variable "enable_hsts" {
  description = "Whether to enable HSTS via zone security_header setting. Leave false until HTTPS certificate issuance and canonical redirects are verified."
  type        = bool
  default     = false
}
