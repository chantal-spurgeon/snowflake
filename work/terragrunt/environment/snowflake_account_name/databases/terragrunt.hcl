# environment/snowflake_account_name/databases/terragrunt.hcl

include "root" {
  path   = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//work/terragrunt"
}

inputs = {
  databases = {
    "db_test_prd" = {
      comment                  = "Production chaos."
      data_retention_time_days = 1
      is_transient            = true

      schemas = {
        "ingest_data" = {
          comment        = "Raw Data"
          is_transient   = true
          managed_access = false
        },
        "share_ready" = {
          comment        = "The final product we love"
          is_transient   = true
          managed_access = true
        }
      }
    },

#    "db_test_prd_replica" = {
#      comment                  = "Disaster Recovery Archive."
#      data_retention_time_days = 1
#      is_transient            = true
#      is_replica              = true
#      primary_database_path    = "MY_ORG_NAME.PRIMARY_PROD_ACCOUNT.DATABASE"
#      schemas                  = {}
#    },
  }

}
