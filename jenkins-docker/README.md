# Jenkins Docker Image with Additional Tools and Configuration

This Dockerfile extends the official Jenkins Docker image (LTS) and adds additional tools and configurations to enhance its functionality.

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Building the Image](#building-the-image)
- [Configuration](#configuration)
- [Usage](#usage)
- [Cleanup](#cleanup)
- [Contributing](#contributing)
- [License](#license)

## Features

- Installs OpenJDK 11, Maven, jq, and AWS CLI
- Installs Docker and configures it to work within the Jenkins environment
- Installs Terraform and other essential tools
- Allows easy user switching between OS operations and Jenkins configuration
- Configures Jenkins with specified plugins, settings, and jobs
- Provides options to customize Jenkins HTTP and HTTPS ports
- Cleans up unnecessary files to reduce image size

## Prerequisites

- Docker installed on the host machine

## Building the Image

To build the Jenkins Docker image, run the following commands:

```bash
docker build \
  --build-arg JENKINS_DOCKER_TERRAFORM_DISTRO=<terraform_distribution_url> \
  --build-arg PLUGINS_FILE=<path_to_plugins_file> \
  --build-arg CONFIG_XML_FILE=<path_to_config_xml_file> \
  --build-arg SCRIPT_APPROVAL_FILE=<path_to_script_approval_file> \
  --build-arg HUDSON_TASKS_FILE=<path_to_hudson_tasks_file> \
  --build-arg JENKINS_JOBS_DIR=<path_to_jenkins_jobs_dir> \
  --build-arg PKCS12_FILE=<path_to_pkcs12_file> \
  --build-arg PKCS12_PASS=<pkcs12_password> \
  --build-arg JENKINS_HTTP_PORT=<custom_http_port> \
  --build-arg JENKINS_HTTPS_PORT=<custom_https_port> \
  -t your/jenkins-docker-image .
```
## Configuration

### Environment Variables

- **JENKINS_USERNAME**: User to swap easily between OS operations and Jenkins configuration.
- **JENKINS_HTTP_PORT**: Custom HTTP port for Jenkins (default is -1, which means the default Jenkins port).
- **JENKINS_HTTPS_PORT**: Custom HTTPS port for Jenkins (default is 8443).

### Configuration Files

- **PLUGINS_FILE**: Text file containing a list of Jenkins plugins to be installed.
- **CONFIG_XML_FILE**: Jenkins configuration XML file.
- **SCRIPT_APPROVAL_FILE**: Jenkins scriptApproval XML file.
- **HUDSON_TASKS_FILE**: Jenkins hudson.tasks.Maven XML file.
- **JENKINS_JOBS_DIR**: Directory containing Jenkins job configurations.
- **PKCS12_FILE**: Path to the PKCS12 file for Jenkins HTTPS configuration.
- **PKCS12_PASS**: Password for the PKCS12 file.
