#!/bin/bash

echo "PICSURE Migration: Begin"

export MIGRATION_SCRIPT_NAME="auth"
export CONTAINER_NAME="picsure_migration_orchestrator_container"  
export S3_PROFILE_NAME=""
export S3_BUCKET_NAME="" 
export S3_IMAGE_FILE_NAME="picsure-db-migration-picsureschema-image.tar.gz"
export DOCKER_IMAGE="dbmi/pic-sure-db-migrations:picsure-db-migration-picsureschema-image"  
export AUTH_MIGRATION_SCRIPT="/picsure-db-migrations/scripts/main/picsure/picsure-migration-orchestrator.sh"


echo "Copy s3://$S3_BUCKET_NAME/$S3_IMAGE_FILE_NAME to Local file system"
aws s3 cp s3://$S3_BUCKET_NAME/$S3_IMAGE_FILE_NAME . --profile $S3_PROFILE_NAME 

echo "Load s3://$S3_BUCKET_NAME/$S3_IMAGE_FILE_NAME to Docker images"
docker load < $S3_IMAGE_FILE_NAME

echo "Check if $CONTAINER_NAME exists  and Remove"
CONTAINER_FOUND=$(docker ps --all --quiet --filter=name=$CONTAINER_NAME) 
if [ -n "$CONTAINER_FOUND" ]; then 
	docker stop $CONTAINER_FOUND && docker rm $CONTAINER_FOUND
fi 


echo "Start Container: $CONTAINER_NAME"
docker run --name $CONTAINER_NAME -d --entrypoint /usr/bin/python3  $DOCKER_IMAGE /app/index.py

echo "Run $MIGRATION_SCRIPT_NAME migration script"
docker exec -i $CONTAINER_NAME bash -c $AUTH_MIGRATION_SCRIPT


echo "Stop and Remove $CONTAINER_NAME"
CONTAINER_FOUND=$(docker ps --all --quiet --filter=name=$CONTAINER_NAME)
if [ -n "$CONTAINER_FOUND" ]; then
	docker stop $CONTAINER_FOUND && docker rm $CONTAINER_FOUND
fi

echo "PICSURE Database Migration: End"