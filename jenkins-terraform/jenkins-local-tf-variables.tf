/*
  This tf vars should store dynamic vars
  
*/

# variable to control OS Distribution. 

locals {
   # list of support Distributions.  Used by jenkins_tf_local_var_dist for validation of Supported Distributions
   valid_os = [ "CENTOS" ]
   centos_user_script = "distro/linux/centos/user-scripts/install-docker.sh"
   
   
   # set user script location using coalesce based on the distribution
   centos_script = var.jenkins_tf_local_var_OS_dist == "CENTOS" ? "user-scripts/linux/centos/install-docker.sh" : ""
   example_script = var.jenkins_tf_local_var_OS_dist == "EXAMPLE" ? "Unreachable Coalesece Example" : ""
   
   user_script = coalesce(local.centos_script,local.example_script)
}


 