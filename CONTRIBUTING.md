# Contributing to avillachlab-jenkins

Please read the [PIC-SURE contributing guide](https://github.com/hms-dbmi/pic-sure/blob/main/CONTRIBUTING.md)
first. It covers the code of conduct, filing issues, and how pull requests are reviewed across
every PIC-SURE repository.

## Building and testing this repo

This repository holds the Jenkins build infrastructure for the Avillach Lab. Standing it up
needs lab AWS credentials, which we cannot share, so an outside contributor cannot run or test
these configurations.

If you find a problem here, please open an issue.

`jenkins-docker` holds the container definition. `jenkins-terraform` and
`non-fisma-infrastructure` hold Terraform, run from inside each directory with `terraform init`
and `terraform plan`.
