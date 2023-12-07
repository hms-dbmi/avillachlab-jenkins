# Table of Contents

- [Variables](#variables)
- [Terraform Backend](#terraform-backend)
- [Outputs](#outputs)

## Variables
- [stack_id](#stack_id)
- [git_commit](#git_commit)
- [jenkins_vpc_id](#jenkins_vpc_id)
- [jenkins_instance_profile_name](#jenkins_instance_profile_name)
- [jenkins_tf_state_bucket](#jenkins_tf_state_bucket)
- [jenkins_subnet_id](#jenkins_subnet_id)
- [jenkins_sg_egress_allow_all_cidr_blocks](#jenkins_sg_egress_allow_all_cidr_blocks)
- [jenkins_sg_ingress_https_cidr_blocks](#jenkins_sg_ingress_https_cidr_blocks)
- [jenkins_config_s3_location](#jenkins_config_s3_location)
- [jenkins_ec2_instance_type](#jenkins_ec2_instance_type)
- [jenkins_tf_local_var_OS_dist](#jenkins_tf_local_var_OS_dist)
- [jenkins_ec2_ebs_volume_size](#jenkins_ec2_ebs_volume_size)
- [jenkins_docker_maven_distro](#jenkins_docker_maven_distro)
- [jenkins_docker_terraform_distro](#jenkins_docker_terraform_distro)
- [jenkins_git_repo](#jenkins_git_repo)
- [program](#program)
- [env_is_open_access](#env_is_open_access)
- [environment_name](#environment_name)
- [is_initialized](#is_initialized)
- [locals](#locals)

## Terraform Backend
- [Terraform Backend Configuration](#terraform-backend-configuration)

## Outputs
- [jenkins-ec2-id](#jenkins-ec2-id)
- [jenkins-ec2-ip](#jenkins-ec2-ip)

# Variables

The following variables are defined in the `jenkins-deploy-tf-variables.tf` and `jenkins-local-tf-variables.tf` file. Adjust these variables based on your specific requirements:

- **stack_id**:
  - Description: Identifier for the Jenkins instance stack.
  - Type: `string`

- **git_commit**:
  - Description: Git commit hash for version tracking.
  - Type: `string`

- **jenkins_vpc_id**:
  - Description: ID of the VPC where Jenkins will be deployed.
  - Type: `string`

- **jenkins_instance_profile_name**:
  - Description: Name of the IAM instance profile attached to the Jenkins EC2 instance.
  - Type: `string`

- **jenkins_tf_state_bucket**:
  - Description: Name of the S3 bucket for storing Terraform state.
  - Type: `string`

- **jenkins_subnet_id**:
  - Description: ID of the subnet where Jenkins will be deployed.
  - Type: `string`

- **jenkins_sg_egress_allow_all_cidr_blocks**:
  - Description: List of CIDR blocks for egress traffic from Jenkins security group.
  - Type: `list(any)`

- **jenkins_sg_ingress_https_cidr_blocks**:
  - Description: List of CIDR blocks for inbound HTTPS traffic to Jenkins security group.
  - Type: `list(any)`

- **jenkins_config_s3_location**:
  - Description: S3 location for Jenkins configuration files.
  - Type: `string`

- **jenkins_ec2_instance_type**:
  - Description: AWS EC2 instance type for Jenkins.
  - Type: `string`

- **jenkins_tf_local_var_OS_dist**:
  - Description: Operating system distribution for Jenkins (e.g., "CENTOS").
  - Type: `string`

- **jenkins_ec2_ebs_volume_size**:
  - Description: Size of the EBS volume attached to the Jenkins EC2 instance.
  - Type: `number`

- **jenkins_docker_maven_distro**:
  - Description: Docker Maven distribution used by Jenkins.
  - Type: `string`

- **jenkins_docker_terraform_distro**:
  - Description: Docker Terraform distribution used by Jenkins.
  - Type: `string`

- **jenkins_git_repo**:
  - Description: Git repository URL for Jenkins.
  - Type: `string`

- **program**:
  - Description: Program identifier.
  - Type: `string`

- **env_is_open_access**:
  - Description: Boolean flag indicating if the environment is open access.
  - Type: `bool`

- **environment_name**:
  - Description: Name of the environment (e.g., "dev").
  - Type: `string`

- **is_initialized**:
  - Description: Flag indicating whether Jenkins is initialized.
  - Type: `string`

Make sure to replace the placeholder values with actual configurations.

# Terraform Backend

```hcl
terraform {
  backend "s3" {
    encrypt = true
  }
}
```

# Outputs

This module defines the following outputs:

- **jenkins-ec2-id**:
  - Description: The ID of the Jenkins EC2 instance.
  - Usage: Use this output to reference the unique identifier of the deployed Jenkins EC2 instance.

- **jenkins-ec2-ip**:
  - Description: The private IP address of the Jenkins EC2 instance.
  - Usage: Use this output to obtain the private IP address assigned to the Jenkins EC2 instance.

These outputs can be utilized in other Terraform objects or scripts to access information about the deployed Jenkins infrastructure.
