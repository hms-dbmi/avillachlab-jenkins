FROM jenkins/jenkins:lts

ARG S3_BUCKET

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root 

RUN echo "s/stack_s3_bucket_var/$S3_BUCKET/"

RUN sed -i "s/stack_s3_bucket_var/$S3_BUCKET/" /var/jenkins_home/config.xml

RUN echo deb http://deb.debian.org/debian stretch-backports main >> /etc/apt/sources.list

RUN apt-get update

RUN apt-get -y install apt-transport-https

RUN apt-get -y install python3-pip

RUN pip3 install --no-input awscli --upgrade

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version 

RUN wget https://www-us.apache.org/dist/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz -P /opt

RUN apt-get -y -t stretch-backports install openjdk-11-jdk

RUN tar -xvzf /opt/apache-maven-3.6.3-bin.tar.gz -C /opt

RUN rm /opt/apache-maven-3.6.3-bin.tar.gz

RUN apt-get install jq -y

RUN `/usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt` || echo "Some errors occurred during plugin installation."

RUN wget https://releases.hashicorp.com/terraform/0.12.31/terraform_0.12.31_linux_amd64.zip && unzip terraform_0.12.31_linux_amd64.zip && mv terraform /usr/local/bin/
