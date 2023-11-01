FROM jenkins/jenkins:lts

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

###### OS configs and package installations ########
# We could run these commands and build an image then configure jenkins only in this dockerfile instead of directly using the jenkins stock image
RUN apt-get update

RUN apt-get -y install apt-transport-https \
    apt-get -y install python3-pip \
    apt-get -y install wget

# maybe not the best way to install awscli 
# see https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
RUN pip3 install --no-input awscli --upgrade --break-system-packages

RUN curl -fsSL https://get.docker.com | sh \
    && docker --version

RUN apt-get -y -t stretch-backports install openjdk-11-jdk-headless
# add customization to allow different versions of maven to be installed 

RUN apt-get -y install maven

RUN apt-get install jq -y

# Check if JENKINS_DOCKER_TERRAFORM_DISTRO is provided and download and unzip Terraform if it is
RUN if [ -n "$JENKINS_DOCKER_TERRAFORM_DISTRO" ]; then \
    wget -c $JENKINS_DOCKER_TERRAFORM_DISTRO -O /opt/terraform.zip && \
    unzip /opt/terraform.zip -d /usr/local/bin/; \
fi

##### Configuration for jenkins ###########

# Check if PLUGINS_FILE is provided and copy it, then run jenkins-plugin-cli
RUN if [ -n "$PLUGINS_FILE" ]; then \
    COPY $PLUGINS_FILE /usr/share/jenkins/ref/plugins.txt && \
    /bin/jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt || echo "Some errors occurred during plugin installation."; \
fi

RUN if [ -n "$CONFIG_XML_FILE" ]; then COPY $CONFIG_XML_FILE /var/jenkins_home/config.xml; fi
RUN if [ -n "$SCRIPT_APPROVAL_FILE" ]; then COPY $SCRIPT_APPROVAL_FILE /var/jenkins_home/scriptApproval.xml; fi
RUN if [ -n "$HUDSON_TASKS_FILE" ]; then COPY $HUDSON_TASKS_FILE /var/jenkins_home/hudson.tasks.Maven.xml; fi
RUN if [ -n "$JENKINS_JOBS_DIR" ]; then COPY $JENKINS_JOBS_DIR /var/jenkins_home/jobs; fi

# Check if either PKCS12_FILE or PKCS12_PASS is provided, and ensure both are provided if one is provided
RUN if [ -n "$PKCS12_FILE" ] || [ -n "$PKCS12_PASS" ]; then \
    if [ -z "$PKCS12_FILE" ] || [ -z "$PKCS12_PASS" ]; then \
        echo "Both PKCS12_FILE and PKCS12_PASS must be provided if either one is provided."; \
        exit 1; \
    fi; \
    # If both are provided, copy the PKCS12_FILE and set the ENV variables
    COPY $PKCS12_FILE /var/jenkins_home/$PKCS12_FILE; \
    ENV JENKINS_OPTS="--httpPort=$JENKINS_HTTP_PORT --httpsPort=$JENKINS_HTTPS_PORT --httpsKeyStore=/var/jenkins_home/$PKCS12_FILE --httpsKeyStorePassword=$PKCS12_PASS -Djenkins.install.runSetupWizard=$RUN_SETUP_WIZARD"; \
else \
    # If both are empty JENKINS_OPTS should not use 
    ENV JENKINS_OPTS="--httpPort=$JENKINS_HTTP_PORT --httpsPort=$JENKINS_HTTPS_PORT -Djenkins.install.runSetupWizard=$RUN_SETUP_WIZARD"; \
fi
USER root

RUN echo deb http://archive.debian.org/debian stretch-backports main >> /etc/apt/sources.list \
    echo deb http://archive.debian.org/debian stretch main >> /etc/apt/sources.list


