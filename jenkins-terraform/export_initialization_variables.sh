#!/bin/bash

export GIT-COMMIT=<Git hash for Jenkins Repo> /
export stack-s3-bucket=<s3 bucket created in prerequisites> /
export stack-id=<environment short name ( dev or prod )> /
export jenkins-subnet-id=<aws subnet-id used for jenkins> /
export jenkins-vpc-id=<aws vpc-id for Jenkins> /
export jenkins-instance-profile-name=<IAM Profile name for Jenkins> /
export jenkins-sg-ingress-http-cidr-blocks=<CIDR block used for Jenkins HTTP Security group> /
export jenkins-sg-ingress-https-cidr-blocks=<CIDR block used for Jenkins HTTPS Security group> /
export jenkins-sg-ingress-ssh-cidr-blocks=<CIDR block used for Jenkins SSH security group> /
export dsm-url=<Deep Security Managers URL> /
export jenkins-config-s3-location=<s3 location that stores Jenkins config.xml> /
export jenkins_ec2_instance_type=<size of the ec2> /
export jenkins_tf_local_var_OS_dist=<os to distribute> / 
export jenkins_ec2_ebs_volume_size=<ebs volume size> /
export jenkins_docker_maven_distr=NO LONGER USED
export jenkins_docker_terraform_distro=<terraform distribution to use>
