FROM jenkins/jenkins:lts

ARG S3_BUCKET

ARG jenkins_docker_maven_distro

ARG jenkins_docker_terraform_distro

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

RUN pip3 install --no-input awscli --upgrade

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version

RUN wget -c $jenkins_docker_maven_distro -O /opt/maven.bin.tar.gz

RUN apt-get -y -t stretch-backports install openjdk-11-jdk-headless

RUN mkdir /opt/maven/

RUN tar -xvzf /opt/maven.bin.tar.gz --strip-components=1 -C /opt/maven/

# Might want to keep the tar around
#RUN rm /opt/maven.bin.tar.gz

RUN apt-get install jq -y

RUN /bin/jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt || echo "Some errors occurred during plugin installation."

# Should look at using the jenkins terraform plugin instead of what we are doing
RUN wget -c $jenkins_docker_terraform_distro -O /opt/terraform.zip 

RUN unzip /opt/terraform.zip -d /usr/local/bin/
