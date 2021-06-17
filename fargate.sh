#!/bin/bash

# Check the .conf/params.conf file in the .conf directory before running the script

function start_project(){
  mkdir ${PROJECT_NAME}
  cp -avr .conf ${PROJECT_NAME}/.conf
  cd ${PROJECT_NAME}
}

function configure_task_execution_role() {
  # Get the task execution role name to check if it exists or not
  TASK_EXECUTION_ROLE_EXISTS=$(aws iam list-roles --query "Roles[?RoleName=='ecsTaskExecutionRole'].RoleName")
  # If the task execution role doesn't exist
  if [ "${TASK_EXECUTION_ROLE_EXISTS}" == "[]" ]
  then
    create_task_execution_role
  fi

  attach_policies_to_role
}

function create_task_execution_role {
  # Creates JSON file for the task execution role
  cat <<EOT >task-execution-assume-role.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOT

  # Creates task execution role and save its ARN
  aws iam create-role --role-name ecsTaskExecutionRole \
    --assume-role-policy-document file://task-execution-assume-role.json --region ${REGION} \
    --query 'Role.Arn' | tr -d '"'

  rm task-execution-assume-role.json
}

function attach_policies_to_role {
  # Attaches the AmazonECSTaskExecutionRolePolicy policy to the new role
  aws iam attach-role-policy --role-name ecsTaskExecutionRole --region ${REGION} \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

  # Attaches the AmazonDynamoDBFullAccess policy to the new role
  aws iam attach-role-policy --role-name ecsTaskExecutionRole --region ${REGION} \
    --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess
}

function configure_ecs_cli() {
  # Configure a CLI profile
  ecs-cli configure profile --access-key ${AWS_ACCESS_KEY_ID} --secret-key ${AWS_SECRET_ACCESS_KEY} \
    --profile-name ${PROFILE_NAME}
}

function create_cluster() {
  # Configure the cluster
  ecs-cli configure --cluster ${CLUSTER_NAME} --config-name ${CLUSTER_NAME} \
    --default-launch-type FARGATE --region ${REGION}

  # Create the cluster
  echo $(ecs-cli up --cluster-config ${CLUSTER_NAME} \
  --ecs-profile ${PROFILE_NAME} --force)  | tr " " "\n" >.conf/cluster.conf
}

function get_cluster_info() {
  while IFS= read -r line; do
    if [[ $line = "vpc-"* ]]; then
      VPC_ID=${line}
    elif [[ $line = "subnet-"* ]]; then
      SUBNET_ID+=(${line})
    fi
  done <.conf/cluster.conf

  cat <<EOF >.conf/cluster.conf
CLUSTER_NAME=${CLUSTER_NAME}
VPC_ID=${VPC_ID}
SUBNET_ID[0]=${SUBNET_ID[0]}
SUBNET_ID[1]=${SUBNET_ID[1]}
EOF
}

function config_security_group() {
  SG_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' | tr -d '"')
  echo SG_ID=${SG_ID} >> .conf/cluster.conf

  aws ec2 authorize-security-group-ingress --group-id ${SG_ID} --protocol tcp --region us-east-1\
  --port ${PORT} --cidr 0.0.0.0/0
}

function create_ecr_repositories() {
  # Login to AWS ECR
  aws ecr get-login-password --region ${REGION} | docker login --username AWS \
  --password-stdin ${ACC_URL}

  for (( i=0; i<${#SERVICE_NAME[@]}; i++ ))
  do
    # Saves the image url
    IMAGE_URL[i]=${ACC_URL}/${IMAGE_NAME[i]}

    # Create repository
    aws ecr create-repository --repository-name ${IMAGE_NAME[i]} --query 'repository.repositoryArn'

    # Tag the docker image
    docker tag ${IMAGE_NAME[i]}:${IMAGE_TAG[i]} ${IMAGE_URL[i]}:${IMAGE_TAG[i]}

    # Push it to your repository
    docker push ${IMAGE_URL[i]}
  done
}

function create_yml() {
  mkdir .yml
  cd .yml

cat <<EOF >docker-compose.yml
version: '3'
services: 
$(for (( i=0; i<${#SERVICE_NAME[@]}; i++ ))
do
    echo "  ${SERVICE_NAME[i]}:
    image: ${IMAGE_URL[i]}:${IMAGE_TAG[i]}"

    if [[ "${PORT[i]}" != '' ]]; then
      echo "    ports:
      - "${PORT[i]}:${PORT[i]}""
    fi

    echo "    logging:
      driver: awslogs
      options: 
        awslogs-group: ecs/${SERVICE_NAME[i]}
        awslogs-region: ${REGION}
        awslogs-stream-prefix: ecs"
done)
EOF

cat <<EOF >ecs-params.yml
version: 1
task_definition:
  task_role_arn: ${TASK_ROLE_ARN}
  task_execution_role: ecsTaskExecutionRole
  ecs_network_mode: awsvpc
  task_size:
    mem_limit: ${TASK_MAX_MEM}
    cpu_limit: ${TASK_MAX_CPU}
run_params:
  network_configuration:
    awsvpc_configuration:
      subnets:
        - "${SUBNET_ID[0]}"
        - "${SUBNET_ID[1]}"
      security_groups:
        - "${SG_ID}"
      assign_public_ip: ENABLED
EOF
}

function docker_compose() {
  ecs-cli compose --project-name ${PROJECT_NAME} service up --create-log-groups \
  --cluster-config ${CLUSTER_NAME} --ecs-profile ${PROFILE_NAME}
}

function get_public_dns_and_ip() {
  TASK_ARN=$(aws ecs list-tasks --cluster ${CLUSTER_NAME} --query 'taskArns[0]' | tr -d '"')
  NETWORK_INTERFACE_ID=$(aws ecs describe-tasks --cluster ${CLUSTER_NAME} --tasks ${TASK_ARN} --query 'tasks[0].attachments[0].details[1].value' | tr -d '"')
  aws ec2 describe-network-interfaces --filters Name=network-interface-id,Values=${NETWORK_INTERFACE_ID} --query 'NetworkInterfaces[0].Association' | tr -d '"'
}


function yes_or_no {
  read -r -p "Are you sure? [y/N] " response
  if [[ "${response,}" == 'y' ]]
  then
      delete
  elif [[ "${response^}" == 'N' ]]
  then
      scale_or_delete
  else
      yes_or_no
  fi
}

function scale_or_delete {
  echo
  echo Do you want to: 
  PS3="Please enter your choice: "
  options=("Scale service" "Delete cluster")
  select opt in "${options[@]}"
  do
      case $opt in
          ${options[0]})
              scale
              break
              ;;
          ${options[1]})
              yes_or_no
              break
              ;;
          *) echo "$REPLY isn't a valid option";;
      esac
  done
}

# Deploy images
function deploy() {
  start_project
  configure_task_execution_role
  configure_ecs_cli
  create_cluster
  get_cluster_info
  config_security_group
  create_ecr_repositories
  create_yml
  docker_compose
  get_public_dns_and_ip
}

function scale() {
  # Scale service
  ecs-cli compose --project-name ${PROJECT_NAME} service scale ${TASKS_DESIRED} \
  --cluster-config ${CLUSTER_NAME} --ecs-profile ${PROFILE_NAME}
}

# Deletes the cluster and the services inside it, then it deletes the directory
function delete() {
  # Delete service
  ecs-cli compose --project-name ${PROJECT_NAME} service down \
  --cluster-config ${CLUSTER_NAME} --ecs-profile ${PROFILE_NAME}
  # Delete cluster
  ecs-cli down --cluster-config ${CLUSTER_NAME} \
  --ecs-profile ${PROFILE_NAME} --force
  # Delete directory 
  cd ../..
  rm -r ${PROJECT_NAME}
}


# Get the params file
source .conf/params.conf

# If the project directory doesn't exist, it creates a project and deploy it
if [ ! -d "${PROJECT_NAME}" ]; then
  deploy
# If it does exist, you can scale or delete the project.
else
  echo "${PROJECT_NAME} already exists."
  cd ${PROJECT_NAME}/.yml
  scale_or_delete
fi
