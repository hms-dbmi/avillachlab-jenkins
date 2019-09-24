FROM jenkins/jenkins:lts-jdk11

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

USER root 

RUN apt-get update

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version 

RUN apt-get install jq -y

RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt

USER root
