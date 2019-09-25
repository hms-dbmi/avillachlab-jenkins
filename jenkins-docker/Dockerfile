FROM jenkins/jenkins:lts-jdk11

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

COPY jobs/pic-sure-database-migrations/main/ /var/jenkins_home/jobs/

COPY jobs/pic-sure-database-migrations/custom/ /var/jenkins_home/jobs/

COPY config.xml /var/jenkins_home/config.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root 

RUN apt-get update

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version 

RUN apt-get install jq -y

RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt

USER root
