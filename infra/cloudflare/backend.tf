# Remote state is stored in a dedicated, private Cloudflare R2 bucket
# separate from Inference Exchange state.
#
# OpenTofu >= 1.10 supports native S3 lockfiles (`use_lockfile = true`)
# backed by Cloudflare R2 conditional writes (If-None-Match: *).
#
# Supply bucket, key, and account endpoint at init time:
#   tofu init -backend-config=backend.hcl
# See backend.hcl.example and infra/cloudflare/README.md.
terraform {
  backend "s3" {}
}
