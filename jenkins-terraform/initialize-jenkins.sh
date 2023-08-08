#!/bin/bash

### BEFORE RUNNING!
# Need to export the variables used in the terraform apply below as env variables or store them in a variable.tf file
# or just replace the variables with the values needed.
# Values should be stored in the global config.xml that is located at the ${jenkins_config_s3_location} variable.
#
# Also need to have jenkins-s3-role on the ec2

#### Script that will be used to initialize a jenkins CI environment.
## Once a Jenkins server is built it is able to recreate itself.
## This should be a replicate of the bash script used in the Create New Jenkins Server.

### Install terraform current distro used is https://releases.hashicorp.com/terraform/0.12.31/terraform_0.12.31_linux_amd64.zip

RUN wget -c $JENKINS_DOCKER_TERRAFORM_DISTRO -O /opt/terraform.zip

RUN unzip /opt/terraform.zip -d /usr/local/bin/


# backend s3 config will always be encrypted
# need to find a better key location that isn't tied to the git commit for the job
terraform init \
-backend-config="bucket=${jenkins_tf_state_bucket}" \
-backend-config="key=jenkins_state/jenkins_${GIT_COMMIT}/terraform.tfstate" \
-backend-config="region=${jenkins_tf_state_region}"

terraform apply -auto-approve \
-var "git_commit=`echo ${GIT_COMMIT} |cut -c1-7`" \
-var "stack_s3_bucket=${stack_s3_bucket}" \
-var "stack_id=${stack_id}" \
-var "jenkins_subnet_id=${jenkins_subnet_id}" \
-var "jenkins_vpc_id=${jenkins_vpc_id}" \
-var "jenkins_instance_profile_name=${jenkins_instance_profile_name}" \
-var "jenkins_sg_ingress_http_cidr_blocks=${jenkins_sg_ingress_http_cidr_blocks}" \
-var "jenkins_sg_ingress_https_cidr_blocks=${jenkins_sg_ingress_https_cidr_blocks}" \
-var "jenkins_sg_egress_allow_all_cidr_blocks=${jenkins_sg_egress_allow_all_cidr_blocks}" \
-var "jenkins_config_s3_location=${jenkins_config_s3_location}" \
-var "jenkins_ec2_instance_type=${jenkins_ec2_instance_type}" \
-var "jenkins_tf_local_var_OS_dist=${jenkins_tf_local_var_OS_dist}" \
-var "jenkins_ec2_ebs_volume_size=${jenkins_ec2_ebs_volume_size}" \
-var "jenkins_docker_maven_distro=${jenkins_docker_maven_distro}" \
-var "jenkins_docker_terraform_distro=${jenkins_docker_terraform_distro}"
