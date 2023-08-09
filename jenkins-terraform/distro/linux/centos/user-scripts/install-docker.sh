#!/bin/bash
sudo yum install wget -y

sh /opt/srce/scripts/start-gsstools.sh
echo "user-data progress starting update"
sudo yum -y update
echo "user-data progress finished update installing epel-release"
sudo yum -y install epel-release
cd /home/centos/jenkins

repo=`echo ${jenkins_git_repo} | awk -F/ '{print $NF}'`
wget ${jenkins_git_repo}/-/archive/${git_commit}/$${repo}.zip
unzip $${repo}.zip -d tmp && tmp/* tmp/$${repo}

sudo mkdir -p /var/jenkins_home/jobs/
sudo mkdir -p /var/log/jenkins-docker-logs
cp -r tmp/jenkins-docker/jobs/* /var/jenkins_home/jobs/

rm -rf tmp

# Jenkins build using IAC
sudo docker build \
   --build-arg JENKINS_DOCKER_MAVEN_DISTRO=${jenkins_docker_maven_distro} \
   --build-arg JENKINS_DOCKER_TERRAFORM_DISTRO=${jenkins_docker_terraform_distro} \
   -t jenkins .

# Download Jenkins config file from s3
for i in {1..5}; do sudo /usr/bin/aws --region us-east-1 s3 cp ${jenkins_config_s3_location} /var/jenkins_home/config.xml && break || sleep 45; done

# copy ssl cert & key from s3
for i in {1..5}; do sudo /usr/bin/aws --region us-east-1 s3 cp s3://${stack_s3_bucket}/certs/jenkins/jenkins.cer /root/jenkins.cer && break || sleep 45; done
for i in {1..5}; do sudo /usr/bin/aws --region us-east-1 s3 cp s3://${stack_s3_bucket}/certs/jenkins/jenkins.key /root/jenkins.key && break || sleep 45; done

# generate keystore file for docker/jenkins use
keystore_pass=`echo $RANDOM | md5sum | head -c 20`
sudo openssl pkcs12 -export -in /root/jenkins.cer -inkey /root/jenkins.key -out /root/jenkins.p12 -password pass:$keystore_pass

#run jenkins docker container
sudo docker run -d --log-driver syslog --log-opt tag=jenkins \
                    -v /var/jenkins_home/jobs:/var/jenkins_home/jobs \
                    -v /var/jenkins_home/config.xml:/usr/share/jenkins/ref/config.xml.override \
                    -v /var/jenkins_home/workspace:/var/jenkins_home/workspace \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    -v /root/jenkins.p12:/root/jenkins.p12 \
                    -p 443:8443 \
                    --restart always \
                    --name jenkins \
                    jenkins \
                    --httpsPort=8443 \
		    --httpsKeyStore=/root/jenkins.p12 \
		    --httpsKeyStorePassword="$keystore_pass"


#sudo docker logs -f jenkins > /var/log/jenkins-docker-logs/jenkins.log &

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")" --silent http://169.254.169.254/latest/meta-data/instance-id)
sudo /usr/bin/aws --region=us-east-1 ec2 create-tags --resources $${INSTANCE_ID} --tags Key=InitComplete,Value=true
