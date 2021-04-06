#!/bin/bash
sudo yum install wget -y
sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/centos/amd64/latest/amazon-cloudwatch-agent.rpm
sudo rpm -U amazon-cloudwatch-agent.rpm
sudo touch /opt/aws/amazon-cloudwatch-agent/etc/custom_config.json
echo "

{
	\"metrics\": {
		
		\"metrics_collected\": {
			\"cpu\": {
				\"measurement\": [
					\"cpu_usage_idle\",
					\"cpu_usage_user\",
					\"cpu_usage_system\"
				],
				\"metrics_collection_interval\": 300,
				\"totalcpu\": false
			},
			\"disk\": {
				\"measurement\": [
					\"used_percent\"
				],
				\"metrics_collection_interval\": 600,
				\"resources\": [
					\"*\"
				]
			},
			\"mem\": {
				\"measurement\": [
					\"mem_used_percent\",
                                        \"mem_available\",
                                        \"mem_available_percent\",
                                       \"mem_total\",
                                        \"mem_used\"
                                        
				],
				\"metrics_collection_interval\": 600
			}
		}
	},
	\"logs\":{
   \"logs_collected\":{
      \"files\":{
         \"collect_list\":[
            {
               \"file_path\":\"/var/log/secure\",
               \"log_group_name\":\"secure\",
               \"log_stream_name\":\"{instance_id} secure\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/log/messages\",
               \"log_group_name\":\"messages\",
               \"log_stream_name\":\"{instance_id} messages\",
               \"timestamp_format\":\"UTC\"
            },
						{
               \"file_path\":\"/var/log/audit/audit.log\",
               \"log_group_name\":\"audit.log\",
               \"log_stream_name\":\"{instance_id} audit.log\",
               \"timestamp_format\":\"UTC\"
            },
						{
               \"file_path\":\"/var/log/yum.log\",
               \"log_group_name\":\"yum.log\",
               \"log_stream_name\":\"{instance_id} yum.log\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/log/jenkins-docker-logs/*\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-app-logs\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Backup Jenkins Home/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Backup_Jenkins_Home\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Create new Jenkins Server/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Create_new_Jenkins_Server\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Create stack_variables.tf Files/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Create_stack_variables.tf_Files\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Destroy Old Jenkins Server/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Destroy_Old_Jenkins_Server\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Docker-AWSCLI/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Docker_AWSCLI\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/List Instance Profiles/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs List_Instance_Profiles\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Update Bucket Policy/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Update_Bucket_Policy\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Update Fence Client Credentials/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Update_Fence_Client_Credentials\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Update HTTPD Certs and Key/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Update_HTTPD_Certs_and_Key\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Update PIC-SURE Token Introspection Token/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Update_PIC_SURE_Token_Introspection_Token\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Update VPC Settings/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Update_VPC_Settings\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Deployment Pipeline/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Deployment_Pipeline\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Move Prod DNS Pointer/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Move_Prod_DNS_Pointer\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Retrieve Build Spec/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Retrieve_Build_Spec\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Retrieve Deployment State/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Retrieve_Deployment_State\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Swap Stacks/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Swap_Stacks\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Teardown and Rebuild Stage Environment/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Teardown_and_Rebuild_Stage_Environment\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Write Stack State/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Write_Stack_State\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Import_and_Rekey_HPDS_Data/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Import_and_Rekey_HPDS_Data\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/PIC-SURE Auth Micro-App Build/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs PIC_SURE_Auth_Micro_App_Build\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/PIC-SURE Pipeline/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs PIC_SURE_Pipeline\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/PIC-SURE Wildfly Image Build/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs PIC_SURE_Wildfly_Image_Build\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/PIC-SURE-API Build/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs PIC_SURE_API_Build\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/PIC-SURE-HPDS Build/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs PIC_SURE_HPDS_Build\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/PIC-SURE-HPDS-UI Docker Build/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs PIC_SURE_HPDS_UI_Docker_Build\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/biodatacatalyst-ui/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs biodatacatalyst_ui\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Await Initialization/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Await_Initialization\",
               \"timestamp_format\":\"UTC\"
            },
            {
               \"file_path\":\"/var/jenkins_home/jobs/Check For Updates/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs Check_For_Updates\",
               \"timestamp_format\":\"UTC\"
            }
         ]
      }
		}
	}


}

" > /opt/aws/amazon-cloudwatch-agent/etc/custom_config.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/custom_config.json  -s

echo "user-data progress starting update"
sudo yum -y update 
echo "user-data progress finished update installing epel-release"
sudo yum -y install epel-release 
echo "user-data progress finished epel-release adding docker-ce repo"
sudo yum-config-manager  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
echo "user-data progress added docker-ce repo starting docker install"
sudo yum -y install docker-ce docker-ce-cli containerd.io
echo "user-data progress finished docker install enabling docker service"
sudo systemctl enable docker
echo "user-data progress finished enabling docker service starting docker"
sudo service docker start
cd /home/centos/jenkins
sudo mkdir -p /var/jenkins_home/jobs/
sudo mkdir -p /var/log/jenkins-docker-logs
cp -r jobs/* /var/jenkins_home/jobs/
sudo docker build --build-arg S3_BUCKET=${stack_s3_bucket} -t avillach-lab-dev-jenkins -f ${stack_jenkins_dockerfile} .
sudo docker run -d -v /var/jenkins_home/workspace:/var/jenkins_home/workspace -v /var/jenkins_home/jobs:/var/jenkins_home/jobs -v /var/run/docker.sock:/var/run/docker.sock -p 80:8080 --name jenkins --restart always avillach-lab-dev-jenkins
echo "setup script finished"

sudo docker logs -f jenkins > /var/log/jenkins-docker-logs/jenkins.log &

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")" --silent http://169.254.169.254/latest/meta-data/instance-id)
sudo docker exec jenkins /usr/local/bin/aws --region=us-east-1 ec2 create-tags --resources $${INSTANCE_ID} --tags Key=InitComplete,Value=true

