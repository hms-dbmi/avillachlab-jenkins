#!\usr\bin\env bash

export GIT_COMMIT=<Git hash for Jenkins Repo> \
export jenkins_tf_state_region=<AWS Region> \
export jenkins_tf_state_bucket=<TF state bucket> \
export stack_s3_bucket=<s3 bucket created in prerequisites> \
export stack_id=<environment short name ( dev or prod )> \
export jenkins_subnet_id=<aws subnet_id used for jenkins> \
export jenkins_vpc_id=<aws vpc_id for Jenkins> \
export jenkins_instance_profile_name=<IAM Profile name for Jenkins> \
export jenkins_sg_ingress_http_cidr_blocks=<CIDR block used for Jenkins HTTP Security group> \
export jenkins_sg_ingress_https_cidr_blocks=<CIDR block used for Jenkins HTTPS Security group> \
export jenkins_sg_ingress_ssh_cidr_blocks=<CIDR block used for Jenkins SSH security group> \
export jenkins_sg_egress_allow_all_cidr_blocks=<CIDR block used for Outbound Access SG> \
export jenkins_config_s3_location=<s3 location that stores Jenkins config.xml> \
export jenkins_ec2_instance_type=<size of the ec2> \
export jenkins_tf_local_var_OS_dist=<os to distribute> \
export jenkins_ec2_ebs_volume_size=<ebs volume size> \
export jenkins_docker_maven_distr=NO LONGER USED \
export jenkins_docker_terraform_distro=<terraform distribution to use>
