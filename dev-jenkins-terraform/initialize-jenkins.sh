#!/bin/bash

#### Script that will be used to initialize a jenkins CI environment.
## Once a Jenkins server is built it is able to recreate itself.
## This should be a replicate of the bash script used in the Create New Jenkins Server.

env > env.txt
terraform init
terraform apply -auto-approve \
-var "git-commit=`echo ${GIT_COMMIT} |cut -c1-7`" \
-var "stack-s3-bucket=${stack_s3_bucket}" \
-var "stack-id=${stack_id}" \
-var "jenkins-subnet-id=${jenkins_subnet_id}" \
-var "jenkins-vpc-id=${jenkins_vpc_id}" \
-var "jenkins-instance-profile-name=${jenkins_instance_profile_name}" \
-var "jenkins-sg-ingress-http-cidr-blocks=${jenkins_sg_ingress_http_cidr_blocks}" \
-var "jenkins-sg-ingress-https-cidr-blocks=${jenkins_sg_ingress_https_cidr_blocks}" \
-var "jenkins-sg-ingress-ssh-cidr-blocks=${jenkins_sg_ingress_ssh_cidr_blocks}" \
-var "ami-id=${ami_id}" \
-var "dsm-url=${dsm_url}" \
-var "jenkins-config-s3-location=${jenkins_config_s3_location}"

aws s3 --sse=AES256 cp terraform.tfstate s3://${stack_s3_bucket}/jenkins_state/jenkins_${GIT_COMMIT}/terraform.tfstate
aws s3 --sse=AES256 cp env.txt s3://${stack_s3_bucket}/jenkins_state/jenkins_${GIT_COMMIT}/last_env.txt

INSTANCE_ID=`terraform state show aws_instance.dev-jenkins | grep "\"i-[a-f0-9]" | cut -f 2 -d "=" | sed 's/"//g'`

while [ -z $(/usr/local/bin/aws --region=us-east-1 ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" | grep InitComplete) ];do echo "still initializing";sleep 10;done

# get Jenkins IP
jenkins_ip_addr=`terraform state show aws_instance.dev-jenkins | grep private_ip | cut -f 2 -d "=" | sed 's/\"//g' | sed 's/ //g' | grep '172.39'`

# update security group for jenkins access
# aws ec2 --region=us-east-1 authorize-security-group-ingress --group-id sg-0ab37675f33775da8 --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${jenkins_ip_addr}/32}]
# aws ec2 --region=us-east-1 update-security-group-rule-descriptions-ingress --group-id sg-0ab37675f33775da8 --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${jenkins_ip_addr}/32,Description="Allow Jenkins"}]

echo "http://$jenkins_ip_addr"