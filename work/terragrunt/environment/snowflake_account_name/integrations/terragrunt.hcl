# environment/snowflake_account_name/integrations/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//work/terragrunt"
}

inputs = {
  storage_integrations = {
    "AWS_S3_DATA_LAKE" = {
      provider                  = "S3"
      storage_aws_role_arn      = "arn:aws:iam::123456789012:role/snowflake-access-role"
      storage_allowed_locations = ["s3://your-project-bucket/data/"]
      type                      = "EXTERNAL_STAGE"
      comment                   = "AWS Storage Integration Staging"
    }

    "GCS_DATA_LAKE" = {
      provider                  = "GCS"
      storage_allowed_locations = ["gcs://your-project-gcp-bucket/raw/"]
      type                      = "EXTERNAL_STAGE"
      comment                   = "Google Cloud Storage Integration Staging"

      # Explicitly supply a null mapping key to satisfy the strict map(any) attribute validation check
      storage_aws_role_arn      = null
    }
  }
}

