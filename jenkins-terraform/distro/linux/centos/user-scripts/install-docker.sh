#!/bin/bash

sh /opt/srce/scripts/start-gsstools.sh
sudo yum -y update

#run jenkins docker container
sudo docker run -d --log-driver syslog --log-opt tag=jenkins \
                    -v /var/jenkins_home/workspace:/var/jenkins_home/workspace \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    -p 443:8443 \
                    --restart always \
                    --name jenkins \
                    jenkins

#sudo docker logs -f jenkins > /var/log/jenkins-docker-logs/jenkins.log &

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")" --silent http://169.254.169.254/latest/meta-data/instance-id)
sudo /usr/bin/aws --region=us-east-1 ec2 create-tags --resources $${INSTANCE_ID} --tags Key=InitComplete,Value=true


while [ "$(aws --region=us-east-1 ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" | jq -r '.Tags[] | select(.Key=="InitComplete") | .Value')" != "TRUE" ]

aws --region=us-east-1 ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" | jq -r '.Tags[] | select(.Key=="InitComplete") | .Value'
