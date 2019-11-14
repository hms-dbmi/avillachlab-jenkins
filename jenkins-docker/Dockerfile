FROM jenkins/jenkins:lts

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

COPY jobs/pic-sure-database-migrations/main/ /var/jenkins_home/jobs/

COPY jobs/pic-sure-database-migrations/custom/ /var/jenkins_home/jobs/

COPY jobs/pic-sure-app-builds/ /var/jenkins_home/jobs/

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root 

RUN echo deb http://deb.debian.org/debian stretch-backports main >> /etc/apt/sources.list

RUN apt-get update

RUN apt-get -y install apt-transport-https

RUN apt-get -y install python3-pip

RUN pip3 install --no-input awscli --upgrade

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version 

RUN wget https://www-us.apache.org/dist/maven/maven-3/3.6.2/binaries/apache-maven-3.6.2-bin.tar.gz -P /opt

RUN apt-get -y -t stretch-backports install openjdk-11-jdk

RUN tar -xvzf /opt/apache-maven-3.6.2-bin.tar.gz -C /opt

RUN rm /opt/apache-maven-3.6.2-bin.tar.gz

RUN apt-get install jq -y

RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt

USER root
