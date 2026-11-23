# Reads CLOUDFLARE_API_TOKEN from the environment so tokens are never written
# into .tfvars, shell history, or state files.
provider "cloudflare" {}
