FROM jenkins/jenkins:lts
# user to swap easily between OS operations and jenkins configuration.
ENV JENKINS_USERNAME=$USER

ARG JENKINS_DOCKER_TERRAFORM_DISTRO
ARG PLUGINS_FILE
ARG CONFIG_XML_FILE
ARG SCRIPT_APPROVAL_FILE
ARG HUDSON_TASKS_FILE
ARG JENKINS_JOBS_DIR
ARG PKCS12_FILE
ARG PKCS12_PASS
ARG JENKINS_HTTP_PORT=-1
ARG JENKINS_HTTPS_PORT=8443
ARG RUN_SETUP_WIZARD=false

# Can use this to swap users back to jenkins user without hardcoding it.  Safe to hardcode swap to root user.
###### OS configs and package installations ########
# We could run these commands and build an image then configure jenkins only in this dockerfile instead of directly using the jenkins stock image
USER root

# debian repos to install openjdk headless? 
# Jenkins must have a better way to manage JRE ....
RUN echo deb http://archive.debian.org/debian stretch-backports main >> /etc/apt/sources.list
RUN echo deb http://archive.debian.org/debian stretch main >> /etc/apt/sources.list

RUN apt-get update

RUN apt-get -y -t stretch-backports install openjdk-11-jdk-headless

RUN apt-get -y install apt-transport-https \
    python3-pip \
    wget

# maybe not the best way to install awscli 
# see https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
RUN pip3 install --no-input awscli --upgrade --break-system-packages

RUN set -e; \
    curl -fsSL https://get.docker.com | sh && \
    docker --version

# maven
RUN apt-get -y install maven
# jq
RUN apt-get install jq -y
# terraform
RUN wget -c $JENKINS_DOCKER_TERRAFORM_DISTRO -O /opt/terraform.zip && \
    unzip /opt/terraform.zip -d /usr/local/bin/ 

# Cleanup
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/*

##### Configuration for jenkins ###########
USER $JENKINS_USERNAME
# Check if PLUGINS_FILE is provided and copy it, then run jenkins-plugin-cli
COPY $PLUGINS_FILE /usr/share/jenkins/ref/plugins.txt 

RUN /bin/jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt || echo "Some errors occurred during plugin installation."

COPY $CONFIG_XML_FILE /var/jenkins_home/config.xml
COPY $SCRIPT_APPROVAL_FILE /var/jenkins_home/scriptApproval.xml
COPY $HUDSON_TASKS_FILE /var/jenkins_home/hudson.tasks.Maven.xml
COPY $JENKINS_JOBS_DIR /var/jenkins_home/jobs
COPY $PKCS12_FILE /var/jenkins_home/$PKCS12_FILE

# Should set env var at runtime using an entrypoint.
ENV JENKINS_OPTS="--httpPort=$JENKINS_HTTP_PORT --httpsPort=$JENKINS_HTTPS_PORT -Djenkins.install.runSetupWizard=$RUN_SETUP_WIZARD --httpsKeyStore=/var/jenkins_home/$PKCS12_FILE --httpsKeyStorePassword=$PKCS12_PASS"
