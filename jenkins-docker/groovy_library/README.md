### Purpose of this directory
This directory contains the groovy scripts that are used by the Jenkins groovy pipelines. The scripts are 
organized into classes and methods.

### How to use the scripts
To load a script in a Jenkins pipeline, you can use the `@Library` annotation to load the library.
If you need to load the library in a Jenkinsfile, you can use the following code at the top of the file:
```groovy
@Library('avillach_lab_pic_sure') _
```

### How to load the Scripts
1. Navigate to Manage Jenkins -> System -> Global Trusted Pipeline Libraries (This is a section in the Jenkins UI)
2. Add a new Library and configure it with the following values
    1. Name: `avillach_lab_pic_sure`
    2. Retrieval Method: `Modern SCM`
    3. Source code management `Git`
    4. Project Repository: `https://github.com/hms-dbmi/avillachlab-jenkins` (unless AIM-AHEAD)
    5. Library Path: `jenkins-docker/groovy_library/`
3. Apply and Save the changes