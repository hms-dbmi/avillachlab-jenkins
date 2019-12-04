#!/usr/bin/env bash
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
sudo docker build -t avillach-lab-dev-jenkins .
sudo docker run -d -v /var/run/docker.sock:/var/run/docker.sock -p 80:8080 --name jenkins --restart always avillach-lab-dev-jenkins
echo "setup script finished"
