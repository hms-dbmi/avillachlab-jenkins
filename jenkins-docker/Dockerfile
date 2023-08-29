FROM jenkins/jenkins:lts

ARG JENKINS_DOCKER_MAVEN_DISTRO

ARG JENKINS_DOCKER_TERRAFORM_DISTRO

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

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

# Should look at using the jenkins terraform plugin instead of what we are doing
RUN wget -c $JENKINS_DOCKER_TERRAFORM_DISTRO -O /opt/terraform.zip 

RUN unzip /opt/terraform.zip -d /usr/local/bin/
