resource "tls_private_key" "provisioning-key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
output "provisioning-private-key" {
  value = tls_private_key.provisioning-key.private_key_pem
}
resource "aws_key_pair" "generated_key" {
  key_name   = "jenkins-provisioning-key-${var.stack-id}-${var.git-commit}"
  public_key = tls_private_key.provisioning-key.public_key_openssh
}


data "template_file" "jenkins-user_data" {
  template = file("install-docker.sh")
  vars = {
    stack_s3_bucket = var.stack-s3-bucket
    stack_id = var.stack-id
    stack_jenkins_dockerfile = var.stack-jenkins-dockerfile
  }
}
////////   SAML   OKTA ////////////////////
resource "okta_group" "jenkins-group" {
  name        = "jenkins_role_admin_${var.project}-${var.env}_${var.stack-id}_${var.git-commit}"
  description = "Jenkins Group"
  users = ["00u2e2omufkPLTMSz357","00u2e52bgxuawhgbp357"] // Add Jason and Paul by default in all new Groups
}

resource "okta_app_saml" "jenkins-saml" {
  label                    = "Jenkins_${var.project}-${var.env}_${var.stack-id}_${var.git-commit}"
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
  label = "Jenkins_${var.project}-${var.env}_${var.stack-id}_${var.git-commit}"
  depends_on = [okta_app_saml.jenkins-saml]
}


data "okta_app_metadata_saml" "jenkins-saml" {
  app_id = "${data.okta_app_saml.jenkins-saml.id}"
  key_id = "${data.okta_app_saml.jenkins-saml.key_id}"
}



output "entity_id" {
  value = regex("[[:alnum:]]+$", "${data.okta_app_metadata_saml.jenkins-saml.entity_id}")
}
//////////////   END OF SAML OKTA ///////////////////


data "template_file" "jenkins-config-xml" {
  template = file("../jenkins-docker/${var.config-xml-filename}")
  vars = {
    okta_saml_app_id = data.okta_app_metadata_saml.jenkins-saml.entity_id
    aws_account_app = var.aws-account-app
    arn_role_app = var.arn-role-app
    arn_role_cnc = var.arn-role-cnc
    arn_role_data = var.arn-role-data
    git_branch_avillachlab_secure_infrastructure = var.git-branch-avillachlab-secure-infrastructure
    git_branch_avillachlab_jenkins_dev_release_control = var.git-branch-avillachlab-jenkins-dev-release-control
    stack_s3_bucket = var.stack-s3-bucket
    jenkins_role_admin_name = var.jenkins-role-admin-name
  }
}
   

data "template_cloudinit_config" "config" {
  gzip          = true
  base64_encode = true

  # user_data
  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.jenkins-user_data.rendered
  }
}

resource "aws_instance" "dev-jenkins" {
  ami = var.cis-centos-linux-ami-id
  instance_type = "m5.xlarge"
  associate_public_ip_address = true
  key_name = aws_key_pair.generated_key.key_name

  iam_instance_profile = var.instance-profile-name

  root_block_device {
    delete_on_termination = true
    encrypted = true
    volume_size = 500
  }



  provisioner "file" {
    source      = "../jenkins-docker"
    destination = "/home/centos/jenkins"
    connection {
      type     = "ssh"
      user     = "centos"
      private_key = tls_private_key.provisioning-key.private_key_pem
      host = self.private_ip
    }
  }

  provisioner "file" {
    content = data.template_file.jenkins-config-xml.rendered
    destination = "/home/centos/jenkins/config.xml"
    connection {
      type     = "ssh"
      user     = "centos"
      private_key = tls_private_key.provisioning-key.private_key_pem
      host = self.private_ip
    }
  }

  vpc_security_group_ids = [
    aws_security_group.inbound-jenkins-from-lma.id,
    aws_security_group.outbound-jenkins-to-internet.id
  ]

  subnet_id = var.subnet-id

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins - ${var.stack-id} - ${var.git-commit}"
  }

  user_data = data.template_cloudinit_config.config.rendered

}
