# environment/snowflake_account_name/users/terragrunt.hcl

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}//work/terragrunt"
}

inputs = {
  users = {
    "myuser" = {
      login_name              = "first.last@company.com"
      email                   = "first.last@company.com"
      first_name              = "First"
      last_name               = "Last"
      default_role            = "OWNER_ROLE"
      default_secondary_roles = ["\"ALL\""]
      default_warehouse       = "TEST_PRD_WH"
      default_namespace       = "DB_TEST_PRD.INGEST_DATA"
      network_policy          = null
      user_type               = "PERSON"
      comment                 = "Data Owner"

      # Update with RSA public key or leave null
      # for unique service profile attributes
      rsa_public_key          = null
      rsa_public_key_2        = null
    }

    "ingest_admin" = {
      login_name              = "ingest_admin"
      email                   = "devops-notify@company.com"
      default_role            = "OWNER_ROLE"
      default_secondary_roles = ["\"ALL\""]
      default_warehouse       = "TEST_PRD_WH"
      default_namespace       = "DB_TEST_PRD.INGEST_DATA"
      network_policy          = "CORPORATE_VPN_ONLY"
      user_type               = "SERVICE"
      comment                 = "Ingest Service Account"
      rsa_public_key          = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArSLIeQeToXiKeza8EAE+O46/4qAK6WnNE1gqbkQbwF9LWi/6uoTxNpY/DGNbM2Qbzr1RQO7CZb3CsklGh39ry2HOTXnRAQRXiiVQgNlson9twYU9mgpVjWO9j1kK1BQdLwp//QuYoywU+Mrm32xACiUoX1TX8hz54PcjAX92RRQ+IrCTY42THTBycUu95thf3uXKSHlmy6xzdLXdFeU2Yebf73OpmBeCfHDDGYNiDOLgZnay/JfVQAKQwuwSHWCxAcgt7etZ9QJqfAhMOT4q4AB7f4C5vgAEUq4xhhPELdCa42vT6KC7WnbLGvu6Govv1sL0yK54Wk+ePflx2MXW1wIDAQAB"

      # Explicitly supply null placeholders
      # for unique human profile attributes
      rsa_public_key_2        = null
      first_name              = null
      last_name               = null
    }
  }
}

