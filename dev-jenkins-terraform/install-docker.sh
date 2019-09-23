#!/usr/bin/env bash
echo "user-data progress starting update"
sudo yum -y update 
echo "user-data progress finished update installing epel-release"
sudo yum -y install epel-release 
echo "user-data progress finished epel-release starting python-pip"
sudo yum -y install python-pip 
sudo pip install --upgrade pip
echo "user-data progress finished python-pip starting docker-compose"
yes | sudo pip install --ignore-installed requests docker-compose
echo "user-data progress finished docker-compose adding docker-ce repo"
sudo yum-config-manager  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
echo "user-data progress added docker-ce repo starting docker install"
sudo yum -y install docker-ce docker-ce-cli containerd.io
echo "user-data progress finished docker install enabling docker service"
sudo systemctl enable docker
echo "user-data progress finished enabling docker service starting docker"
sudo service docker start
cd /opt/local/jenkins_home
tar -xvzf jobs.tar.gz
mv jobs/pic-sure-database-migrations/main/* jobs/
mv jobs/pic-sure-database-migrations/custom/* jobs/
rm -rf pic-sure-database-migrations
cd /home/centos/jenkins
sudo docker-compose -f docker-compose-install-plugins.yml up
sudo docker-compose up -d
echo "setup script finished"
