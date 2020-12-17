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
               \"file_path\":\"/var/jenkins_home/jobs/PIC-SURE-HPDS-UI-copdgene/**/log\",
               \"log_group_name\":\"jenkins-logs\",
               \"log_stream_name\":\"{instance_id} ${stack_id} jenkins-build-logs PIC_SURE_HPDS_UI_copdgene\",
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

# Trend Mirco

ACTIVATIONURL='dsm://dsm.datastage.hms.harvard.edu:4120/'
MANAGERURL='https://dsm.datastage.hms.harvard.edu:443'
CURLOPTIONS='--silent --tlsv1.2'
linuxPlatform='';
isRPM='';
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo You are not running as the root user.  Please try again with root privileges.;
    logger -t You are not running as the root user.  Please try again with root privileges.;
    exit 1;
fi;
if ! type curl >/dev/null 2>&1; then
    echo "Please install CURL before running this script."
    logger -t Please install CURL before running this script
    exit 1
fi
curl $MANAGERURL/software/deploymentscript/platform/linuxdetectscriptv1/ -o /tmp/PlatformDetection $CURLOPTIONS --insecure
if [ -s /tmp/PlatformDetection ]; then
    . /tmp/PlatformDetection
else
    echo "Failed to download the agent installation support script."
    logger -t Failed to download the Deep Security Agent installation support script
    exit 1
fi
platform_detect
if [[ -z "$${linuxPlatform}" ]] || [[ -z "$${isRPM}" ]]; then
    echo Unsupported platform is detected
    logger -t Unsupported platform is detected
    exit 1
fi
echo Downloading agent package...
if [[ $isRPM == 1 ]]; then package='agent.rpm'
    else package='agent.deb'
fi
curl -H "Agent-Version-Control: on" $MANAGERURL/software/agent/$${runningPlatform}$${majorVersion}/$${archType}/$package?tenantID= -o /tmp/$package $CURLOPTIONS --insecure
echo Installing agent package...
rc=1
if [[ $isRPM == 1 && -s /tmp/agent.rpm ]]; then
    rpm -ihv /tmp/agent.rpm
    rc=$?
elif [[ -s /tmp/agent.deb ]]; then
    dpkg -i /tmp/agent.deb
    rc=$?
else
    echo Failed to download the agent package. Please make sure the package is imported in the Deep Security Manager
    logger -t Failed to download the agent package. Please make sure the package is imported in the Deep Security Manager
    exit 1
fi
if [[ $${rc} != 0 ]]; then
    echo Failed to install the agent package
    logger -t Failed to install the agent package
    exit 1
fi
echo Install the agent package successfully
sleep 15
/opt/ds_agent/dsa_control -r
/opt/ds_agent/dsa_control -a $ACTIVATIONURL "policyid:14"


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
sudo docker build --build-arg S3_BUCKET=${stack_s3_bucket} -t avillach-lab-dev-jenkins .
# copy ssl cert & key from s3
for i in 1 2 3 4 5; do sudo /usr/local/bin/aws --region us-east-1 s3 cp s3://${stack_s3_bucket}/certs/jenkins/jenkins.cer /root/jenkins.cer && break || sleep 45; done
for i in 1 2 3 4 5; do sudo /usr/local/bin/aws --region us-east-1 s3 cp s3://${stack_s3_bucket}/certs/jenkins/jenkins.key /root/jenkins.key && break || sleep 45; done
# convert key to jenkins recognizable format
sudo openssl rsa -in /root/jenkins.key -out /root/jenkins.pk1.key

#run jenkins docker container
sudo docker run -d -v /var/jenkins_home/jobs:/var/jenkins_home/jobs \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    -v /root/jenkins.cer:/root/jenkins.cer \
                    -v /root/jenkins.pk1.key:/root/jenkins.pk1.key \
                    -p 443:8443 \
                    --restart always \
                    --name jenkins \
                    avillach-lab-dev-jenkins \
                    --httpsPort=8443 \
                    --httpsCertificate=/root/jenkins.cer \
                    --httpsPrivateKey=/root/jenkins.pk1.key

for i in 1 2 3 4 5; do sudo /usr/local/bin/aws --region us-east-1 s3 cp s3://${stack_s3_bucket}/domain-join.sh /root/domain-join.sh && break || sleep 45; done
cd /root
sudo bash domain-join.sh

echo "setup script finished"

sudo docker logs -f jenkins > /var/log/jenkins-docker-logs/jenkins.log &

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")" --silent http://169.254.169.254/latest/meta-data/instance-id)
sudo docker exec jenkins /usr/local/bin/aws --region=us-east-1 ec2 create-tags --resources $${INSTANCE_ID} --tags Key=InitComplete,Value=true

