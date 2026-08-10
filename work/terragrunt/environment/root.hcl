# environment/root.hcl

locals {
  # Load the shared account configurations
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  snowflake_account = local.account_vars.locals.snowflake_account
  authenticator     = local.account_vars.locals.authenticator
  user              = local.account_vars.locals.user
  role              = local.account_vars.locals.role
  private_key       = local.account_vars.locals.private_key

  # CONFIGURATION FIX: Reverted back to your exact account.hcl variable key name
  private_key_pass  = local.account_vars.locals.private_key_pass
}

inputs = {
  snowflake_account = local.snowflake_account
  snowflake_user    = local.user
  snowflake_role    = local.role
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "snowflake" {
  account                = "${local.snowflake_account}"
  user                   = "${local.user}"
  role                   = "${local.role}"
  authenticator          = "${local.authenticator}"
  private_key            = "${replace(local.private_key, "\n", "\\n")}"
  private_key_passphrase = "${local.private_key_pass}"

  experimental_features_enabled = ["PROVIDER_CONFIGURATION_ACCOUNT_FALLBACK"]
  preview_features_enabled      = ["snowflake_storage_integration_resource"]
}
EOF
}

#Uncomment and configure for a remote statefile on an s3 bucket
#remote_state {
#  backend = "s3"
#  generate = {
#    path      = "backend.tf"
#    if_exists = "overwrite"
#  }
#  config = {
#    bucket = "my-snowflake-tf-state-bucket"
#    key    = "$${path_relative_to_include()}/terraform.tfstate"
#    region = "us-east-1"
#  }
#}


#Uncomment and configure for a remote statefile on a gcp bucket
#remote_state {
#  backend = "gcs"  
#  generate = {
#    path      = "backend.tf"
#    if_exists = "overwrite_terragrunt"
#  }
#  config = {
#    project  = "your-gcp-project-id"
#    location = "us-central1"
#    bucket   = "your-unique-gcs-bucket-name"
#    prefix   = "${path_relative_to_include()}"
#  }
#}


#Uncomment and configure for a remote statefile on an azure bucket
#remote_state {
#  backend = "azurerm"  
#  generate = {
#    path      = "backend.tf"
#    if_exists = "overwrite_terragrunt"
#  }
#  config = {
#    resource_group_name  = "your-resource-group-name"
#    storage_account_name = "youruniquestorageaccount" # Must be globally unique, 3-24 lowercase letters/numbers
#    container_name       = "terraform-state-container"
#    key                  = "${path_relative_to_include()}/terraform.tfstate"
#  }
#}


#Uncomment and configure for a local statefile
#remote_state {
#  backend = "local" 
#  generate = {
#    path      = "backend.tf"
#    if_exists = "overwrite_terragrunt"
#  }
#  config = {
#    path = "${get_terragrunt_dir()}/terraform.tfstate"
#  }
#}


