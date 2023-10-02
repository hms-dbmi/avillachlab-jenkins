FROM jenkins/jenkins:lts

ARG JENKINS_DOCKER_TERRAFORM_DISTRO
ARG PLUGINS_FILE
ARG CONFIG_XML_FILE
ARG SCRIPT_APPROVAL_FILE
ARG HUDSON_TASKS_FILE
ARG JENKINS_JOBS_DIR
ARG PKCS12_FILE
ARG PKCS12_PASS

COPY $PLUGINS_FILE /usr/share/jenkins/ref/plugins.txt

COPY $CONFIG_XML_FILE /var/jenkins_home/config.xml.override

COPY $SCRIPT_APPROVAL_FILE /var/jenkins_home/scriptApproval.xml

COPY $HUDSON_TASKS_FILE /var/jenkins_home/hudson.tasks.Maven.xml

COPY $JENKINS_JOBS_DIR /var/jenkins_home/jobs

COPY $PKCS12_FILE /var/jenkins_home/jenkins.p12

ENV JENKINS_OPTS="--httpPort=-1 --httpsPort=8443 --httpsKeyStore=/var/jenkins_home/jenkins.p12 --httpsKeyStorePassword=$PKCS12_PASS"

USER root

RUN echo deb http://archive.debian.org/debian stretch-backports main >> /etc/apt/sources.list

RUN echo deb http://archive.debian.org/debian stretch main >> /etc/apt/sources.list

RUN apt-get update

RUN apt-get -y install apt-transport-https

RUN apt-get -y install python3-pip

RUN apt-get -y install wget

RUN pip3 install --no-input awscli --upgrade --break-system-packages

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version

RUN apt-get -y -t stretch-backports install openjdk-11-jdk-headless

RUN apt-get -y install maven

RUN apt-get install jq -y

RUN /bin/jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt || echo "Some errors occurred during plugin installation."

RUN wget -c $JENKINS_DOCKER_TERRAFORM_DISTRO -O /opt/terraform.zip 

RUN unzip /opt/terraform.zip -d /usr/local/bin/
