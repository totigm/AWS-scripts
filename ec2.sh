#!/bin/bash

dockerChoice() {
  read -p "Do you want to download a DockerHub (DH) image or use a local one? 
Enter DH for DockerHub, or LD for Local Docker
" DOCKER_HUB_LOCAL
  DOCKER_HUB_LOCAL=${DOCKER_HUB_LOCAL^^}
  echo 
}

localDocker() {
  read -p "Enter your Docker image name " IMAGE_NAME
  read -p "Enter your Docker image tag " IMAGE_TAG
}

dockerHub() {
  read -p "Enter your DockerHub username " DH_USERNAME
  read -p "Enter your DockerHub image name " DH_IMAGE_NAME
  read -p "Enter your DockerHub image tag " IMAGE_TAG

  DH_IMAGE_PATH=${DH_USERNAME}/${DH_IMAGE_NAME}
}

# Choose to use DockerHub or local docker
function readDocker() {
  dockerChoice
  while [ $DOCKER_HUB_LOCAL != "DH" -a $DOCKER_HUB_LOCAL != "LD" ]; do
       dockerChoice # Loop execution
  done

  if [ $DOCKER_HUB_LOCAL == "DH" ]
  then
  dockerHub
  else
  localDocker
  fi
}

# Read input from user
function readAll() {
  echo 'You should have the AWS CLI (https://swrks.co/install-aws-cli) installed

Names should conform with DNS requirements:
 - Should not contain uppercase characters
 - Should not contain underscores (_)
 - Should be between 3 and 63 characters long
 - Should not end with a dash
 - Cannot contain two, adjacent periods
 - Cannot contain dashes next to periods (e.g., "my-.name.com" and "my.-name" are invalid)'

  read -p "Enter your name " NAME
  read -p "Enter your cluster name " CLUSTER_NAME
  read -p "Enter your task definition name " TASK_DEFINITION_NAME
  read -p "Enter the max memory that your task can use " TASK_MAX_MEM
  read -p "Enter the max CPU that your task can use " TASK_MAX_CPU
  read -p "Enter your desired task count " DESIRED_TASK_COUNT
  read -p "Enter your desired instance count " DESIRED_INSTANCE_COUNT
  read -p "Enter your service name " SERVICE_NAME
  readDocker
  read -p "Enter your docker container port " CONTAINER_PORT
  read -p "Enter the host port " HOST_PORT
}

# Set constants based on inputs
function setConsts() {
  ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' | tr -d '"')
  REGION=us-east-1
  BUCKET_NAME=${NAME}-${CLUSTER_NAME}-${TASK_DEFINITION_NAME}
  KEY_NAME=aws-${NAME}
  ACC_URL=${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
  REPOSITORY_NAME=${CLUSTER_NAME}/${IMAGE_NAME}
}

function create_security_group() {
  # https://swrks.co/security-group
  SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name ${NAME}_SG_${REGION} --description "Security group for ${NAME} on ${REGION}" --query 'GroupId' | tr -d '"')
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 22 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_ID} --protocol tcp --port 80 --cidr 0.0.0.0/0
}

function create_cluster() {
  # Create cluster
  aws ecs create-cluster --cluster-name ${CLUSTER_NAME}
}

function create_s3_bucket() {
  # Create S3 bucket
  aws s3api create-bucket --bucket ${BUCKET_NAME}

  # Create new folder
  mkdir ${CLUSTER_NAME}
  cd ${CLUSTER_NAME}

  # Create config file
  echo ECS_CLUSTER=${CLUSTER_NAME} >ecs.config

  # Copy the config file to the bucket
  aws s3 cp ecs.config s3://${BUCKET_NAME}/ecs.config

  # Create the S3 copy shell script so the EC2 instance can use it
  cat <<EOT >>copy-ecs-config-to-s3
#!/bin/bash

yum install -y aws-cli
aws s3 cp s3://${BUCKET_NAME}/ecs.config /etc/ecs/ecs.config
EOT
}

function create_ec2_instance() {
  # Create SSH keypair
  aws ec2 create-key-pair --key-name ${KEY_NAME} --query 'KeyMaterial' \
  --output text >$PWD/${KEY_NAME}.pem

  # Create EC2 Container instance
  INSTANCE_ID=$(aws ec2 run-instances --image-id ami-2b3b6041 --count ${DESIRED_INSTANCE_COUNT} \
  --instance-type t2.micro --iam-instance-profile Name=ecsInstanceRole --key-name ${KEY_NAME} \
  --security-group-ids ${SECURITY_GROUP_ID} --user-data file://copy-ecs-config-to-s3 \
  --query 'Instances[0].InstanceId' | tr -d '"')
}

function create_ecr_repository() {
  # Login to AWS ECR
  aws ecr get-login-password --region ${REGION} | docker login --username AWS \
  --password-stdin ${ACC_URL}

  # Create repository
  aws ecr create-repository --repository-name ${REPOSITORY_NAME}

  # Pull image from DockerHub
  docker pull ${DH_IMAGE_PATH}:${IMAGE_TAG}

  # Tag the docker image
  if [ $DOCKER_HUB_LOCAL == "DH" ]
  then
    docker tag ${DH_IMAGE_PATH}:${IMAGE_TAG} ${ACC_URL}/${REPOSITORY_NAME}:${IMAGE_TAG}
  else
    docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ACC_URL}/${REPOSITORY_NAME}:${IMAGE_TAG}
  fi

  # Push it to your repository
  docker push ${ACC_URL}/${REPOSITORY_NAME}
}

function create_task_definition() {
  # Create JSON file for the task definition
  cat <<EOT >>${TASK_DEFINITION_NAME}-task-definition.json
{
  "containerDefinitions": [
    {
      "name": "${IMAGE_NAME}",
      "image": "${ACC_URL}/${CLUSTER_NAME}/${IMAGE_NAME}:${IMAGE_TAG}",
      "portMappings": [
        {
          "containerPort": ${CONTAINER_PORT},
          "hostPort": ${HOST_PORT}
        }
      ],
      "memory": ${TASK_MAX_MEM},
      "cpu": ${TASK_MAX_CPU}
    }
  ],
  "family": "${TASK_DEFINITION_NAME}"
}
EOT

  # Register the task definition based on the JSON file
  aws ecs register-task-definition --cli-input-json file://${TASK_DEFINITION_NAME}-task-definition.json
}

function create_service() {
  # Create service based on the task definition
  aws ecs create-service --cluster ${CLUSTER_NAME} --service-name ${SERVICE_NAME} \
  --task-definition ${TASK_DEFINITION_NAME} --desired-count ${DESIRED_TASK_COUNT}
}

# Call every function
readAll
setConsts
create_security_group
create_cluster
create_s3_bucket
create_ec2_instance
create_ecr_repository
create_task_definition
create_service

# Show the public DNS
aws ec2 describe-instances --instance-id ${INSTANCE_ID} --query 'Reservations[].Instances[].PublicDnsName' --output table
