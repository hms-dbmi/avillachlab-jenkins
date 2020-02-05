Prerequisites:

AWS CLI installed and configured with admin access to the C&C account.
Terraform installed
Git installed


Create new S3 bucket for new Jenkins instance to use setting the following options DURING CREATION some can't be set after
   - bucket should be named using the following template : avillach-biodatacatalyst-deployments-<Random 7 hex digits>
   - Object Locking must be enabled
   - Encryption should be AES-256
   - Enable Object-level logging as secrets are stored in this bucket
   - Enable versioning
   - Server access logging enabled (hms-dbmi-cnc-cloudtrail, no target prefix)

Clone https://github.com/hms-dbmi/avillachlab-jenkins

Run the following commands after replacing all __VARIABLE_NAME__ entries with their correct values for the environment:

-----------------------------------------------------

cd dev-jenkins-terraform
env > env.txt
terraform init
terraform apply -auto-approve \
-var "git-commit=__GIT_COMMIT_FOR_JENKINS_REPO__" \
-var "stack-s3-bucket=__S3_BUCKET_NAME_YOU_CREATED__" \
-var "stack-id=__S3_BUCKET_NAME_SUFFIX__" \
-var "subnet-id=__JENKINS_SUBNET_ID__" \
-var "vpc-id=__JENKINS_VPC_ID__" \
-var "instance-profile-name=__JENKINS_INSTANCE_PROFILE_NAME__" \
-var "access-cidr=__JENKINS_ACCESS_CIDR__" \
-var "provisioning-cidr=__JENKINS_PROVISIONING_CIDR__"

aws s3 --sse=AES256 cp terraform.tfstate s3://${stack_s3_bucket}/jenkins_state_${GIT_COMMIT}/terraform.tfstate 
aws s3 --sse=AES256 cp env.txt s3://${stack_s3_bucket}/jenkins_state_${GIT_COMMIT}/last_env.txt

INSTANCE_ID=`terraform state show aws_instance.dev-jenkins | grep "\"i-[a-f0-9]" | cut -f 2 -d "=" | sed 's/"//g'`

while [ -z $(/usr/local/bin/aws --region=us-east-1 ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" | grep InitComplete) ];do echo "still initializing";sleep 10;done

echo "http://`terraform state show aws_instance.dev-jenkins | grep private_ip | cut -f 2 -d "=" | sed 's/\"//g' | sed 's/ //g'`"

-----------------------------------------------------

Set Bucket Policy in the Permissions section for the bucket to the following after replacing __BUCKET_NAME__ with the bucket name:

-----------------------------------------------------
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::191687121306:role/hms-dbmi-cnc-role"
            },
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:PutObjectAcl",
                "s3:GetObjectAcl",
                "s3:GetObjectTagging",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::__BUCKET_NAME__/*"
        },
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::752463128620:role/system/jenkins-s3-role"
            },
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:PutObjectAcl",
                "s3:GetObjectAcl",
                "s3:GetObjectTagging",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::__BUCKET_NAME__/*"
        }
    ]
}
-----------------------------------------------------



Set stack_s3_bucket Value to new S3 bucket name in new Jenkins
   - Manage Jenkins > Configure System
   - under "Global properties" set stack_s3_bucket to the new bucket created in the first step

Add the following arn as a trusted entity in the hms-dbmi-cnc-role in the prod account:
   - https://console.aws.amazon.com/iam/home?region=us-east-1#/roles/hms-dbmi-cnc-role?section=trust
   - example template : 

   {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:sts::752463128620:assumed-role/jenkins-s3-role/< instance id of the jenkins ec2 you just created >"
      },
      "Action": "sts:AssumeRole",
      "Condition": {}
    }

   - example : 

   {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:sts::752463128620:assumed-role/jenkins-s3-role/i-0615f53dd368cbdfc"
      },
      "Action": "sts:AssumeRole",
      "Condition": {}
    }

Switch to Jenkins Configuration View ( DO NOT QUEUE UP THE JOBS! Wait for each to complete successfully before going on to the next. )

Run Jenkins Build "Create stack_variables.tf files"
Run Jenkins Build "Update VPC Settings" after confirming the following:
   - confirm that the R53_Zone_ID is correct for the prod account Route 53 Zone
   - confirm that the vpc and subnet group names are correct for the prod account
Run Jenkins Build "Update PIC-SURE Token Introspection Token"
Run Jenkins Build "Update Fence Client Credentials"
   - provide the correct Fence Client ID and Client Secret as provided by the Fence team
Run Jenkins Build "Update HTTPD Certs and Key"
   - provide the correct Cert, Chain and Key file for the production HTTPD server


Switch to the Deployment View

Run Jenkins Build Check For Updates
   - The first time this runs it will take about 1.5 hours because it has to rekey the data.

Run Jenkins Build Swap Stacks
   - This will point the internal production CNAME at the current stage environment
   - The current stage environment becomes prod and the current prod environment becomes stage

Run Jenkins Build Check For Updates
   - This time it should only take about a half hour because the data has already been rekeyed.





