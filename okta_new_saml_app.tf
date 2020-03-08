resource "okta_group" "jenkins-group" {
  name        = "jenkins_role_admin_${var.project}-${var.env}_${var.stack-id}_${var.git-commit}"
  description = "Jenkins Group"
  users = ["00u2e2omufkPLTMSz357","00u2e52bgxuawhgbp357"] // Add Jason and Paul by default in all new Groups
}



resource "okta_app_saml" "jenkins-saml" {
  label                    = "jenkins_saml_${var.project}-${var.env}_${var.stack-id}_${var.git-commit}"
  sso_url                  = "http://${aws_instance.dev-jenkins.public_dns}/securityRealm/finishLogin"
  recipient                = "http://${aws_instance.dev-jenkins.public_dns}/securityRealm/finishLogin"
  destination              = "http://${aws_instance.dev-jenkins.public_dns}/securityRealm/finishLogin"
  audience                 = "Jenkins-users"
  subject_name_id_template = "$${user.userName}"
  subject_name_id_format   = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
  response_signed          = true
  signature_algorithm      = "RSA_SHA256"
  digest_algorithm         = "SHA256"
  honor_force_authn        = true
  authn_context_class_ref  = "urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport"

  attribute_statements {
    type         = "GROUP"
    name         = "Group"
    filter_type  = "REGEX"
    filter_value = "jenkins_role_.*"
    namespace = "urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified"
    values = []
  }
  lifecycle {
  ignore_changes = [groups]
}
}

resource "okta_app_group_assignment" "jenkins-group-app-saml" {
  app_id   = okta_app_saml.jenkins-saml.id
  group_id = okta_group.jenkins-group.id
}

data "okta_app_saml" "jenkins-saml" {
  label = "jenkins_saml_${var.project}-${var.env}_${var.stack-id}_${var.git-commit}"
  depends_on = [okta_app_saml.jenkins-saml]
}


data "okta_app_metadata_saml" "jenkins-saml" {
  app_id = "${data.okta_app_saml.jenkins-saml.id}"
  key_id = "${data.okta_app_saml.jenkins-saml.key_id}"
}

output "entity_id" {
  value = regex("[[:alnum:]]+$", "${data.okta_app_metadata_saml.jenkins-saml.entity_id}")

}

