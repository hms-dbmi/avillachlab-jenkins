#!/bin/bash
echo "ENABLE_PODMAN=true" | sudo tee /opt/srce/startup.config

sh /opt/srce/scripts/start-gsstools.sh
sudo yum -y update

# grab image tar
aws s3 cp s3://${jenkins_tf_state_bucket}/containers/jenkins/jenkins.tar.gz jenkins.tar.gz

# load image
load_result=$(podman load -i jenkins.tar.gz)
image_tag=$(echo "$load_result" | grep -o -E "jenkins:[[:alnum:]_]+")

CONTAINER_NAME=jenkins

podman rm -f $CONTAINER_NAME || true

podman run -d --privileged \
    --log-driver=journald \
    --log-opt tag=jenkins \
    -v /var/run/podman/podman.sock:/var/run/docker.sock \
    -p 443:8443 \
    --name $CONTAINER_NAME \
    --env GITLAB_USER=$GITLAB_USER \
    --env GITLAB_TOKEN=$GITLAB_TOKEN \
    $image_tag

# systemd setup.
podman generate systemd --name $CONTAINER_NAME --restart-policy=always --files

sudo mv container-$CONTAINER_NAME.service /etc/systemd/system/

sudo restorecon -v /etc/systemd/system/container-$CONTAINER_NAME.service

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable container-$CONTAINER_NAME.service
sudo systemctl restart container-$CONTAINER_NAME.service

echo "Verifying container-$CONTAINER_NAME.service status..."
sudo systemctl is-enabled container-$CONTAINER_NAME.service
sudo systemctl status container-$CONTAINER_NAME.service --no-pager

#sudo docker logs -f jenkins > /var/log/jenkins-docker-logs/jenkins.log &

INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")" --silent http://169.254.169.254/latest/meta-data/instance-id)
sudo /usr/bin/aws --region=us-east-1 ec2 create-tags --resources $${INSTANCE_ID} --tags Key=InitComplete,Value=true

