# ---------------------------------------------------------------------------- #
# Materials borrowed from
# https://github.com/terraform-aws-modules/terraform-aws-ecs/tree/master/examples/fargate
# ---------------------------------------------------------------------------- #

provider "aws" {
  # profile = "default"

  region = local.region
  # default_tags {
  #   tags = var.aws_tags
  # }
}

locals {
  region = "us-west-2"
  name   = "teleport-ecs"



  container_name = "teleport-ecsdemo"
  container_port = 3000

  vpc_id = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets = module.vpc.public_subnets
  vpc_cidr_block = module.vpc.vpc_cidr_block

  # tags = {
  #   Name       = local.name
  #   Example    = local.name
  #   Repository = "https://github.com/terraform-aws-modules/terraform-aws-ecs"
  # }
}

# ---------------------------------------------------------------------------- #
# uncomment this section to create a new VPC to
# ---------------------------------------------------------------------------- #
# data "aws_availability_zones" "available" {}
# locals {
#   vpc_cidr = "10.0.0.0/16"
#   azs      = slice(data.aws_availability_zones.available.names, 0, 3)
# }
# module "vpc" {
#   source  = "terraform-aws-modules/vpc/aws"
#   version = "~> 5.0"

#   name = local.name
#   cidr = local.vpc_cidr

#   azs             = local.azs
#   private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
#   public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

#   enable_nat_gateway = true
#   single_nat_gateway = true

#   tags = local.tags
# }


################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source = "../modules/cluster"

  cluster_name = local.name
  create_cloudwatch_log_group = false

  # tags = local.tags
}

################################################################################
# Service
################################################################################

module "ecs_service" {
  source = "../modules/service"

  name        = local.name
  cluster_arn = module.ecs_cluster.arn

  cpu    = 1024
  memory = 4096

  # Enables ECS Exec
  enable_execute_command = true

  enable_autoscaling = false

  # Container definition(s)
  container_definitions = {

    fluent-bit = {
      cpu       = 512
      memory    = 1024
      essential = true
      image     = nonsensitive(data.aws_ssm_parameter.fluentbit.value)
      firelens_configuration = {
        type = "fluentbit"
      }
      memory_reservation = 50
      user               = "0"
    }

    (local.container_name) = {
      cpu       = 512
      memory    = 1024
      essential = true
      image     = "public.ecr.aws/aws-containers/ecsdemo-frontend:776fd50"
      port_mappings = [
        {
          name          = local.container_name
          containerPort = local.container_port
          hostPort      = local.container_port
          protocol      = "tcp"
        }
      ]

      # Example image used requires access to write to root filesystem
      readonly_root_filesystem = false

      dependencies = [{
        containerName = "fluent-bit"
        condition     = "START"
      }]

      enable_cloudwatch_logging = false
      log_configuration = {
        logDriver = "awsfirelens"
        options = {
          Name                    = "firehose"
          region                  = local.region
          delivery_stream         = "my-stream"
          log-driver-buffer-limit = "2097152"
        }
      }

      linux_parameters = {
        capabilities = {
          add = []
          drop = [
            "NET_RAW"
          ]
        }
      }

      memory_reservation = 100
    }
  }

  subnet_ids = local.private_subnets
  security_group_rules = {
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  service_tags = {
    "ServiceTag" = "Tag on service level"
  }

  # tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

data "aws_ssm_parameter" "fluentbit" {
  name = "/aws/service/aws-for-fluent-bit/stable"
}


# ---------------------------------------------------------------------------- #
# outputs
# These outputs are dependant on your local machine being authenticated
# to Teleport and logged into an AWS resource with appropriate permissions. 
# ---------------------------------------------------------------------------- #
output "ecs_list_tasks" {
  description = "List running tasks in the ECS Cluster"
  value       = <<-ECS_DESCRIBE
    tsh aws ecs list-tasks \
        --cluster ${module.ecs_cluster.name} 
    ECS_DESCRIBE
}
output "ecs_task_last_status" {
  description = "Exec will not work until last status is RUNNING"
  value       = <<-ECS_DESCRIBE
    tsh aws ecs describe-tasks \
        --cluster ${module.ecs_cluster.name} \
        --tasks $(tsh aws ecs list-tasks \
          --cluster ${module.ecs_cluster.name} | \
          jq -r ".taskArns[0]") | \
          jq -r ".tasks[0].lastStatus"
    ECS_DESCRIBE
}
output "ecs_task_list_containers" {
  description = "See other containers to exec into"
  value       = <<-ECS_DESCRIBE
    tsh aws ecs describe-tasks \
        --cluster ${module.ecs_cluster.name} \
        --tasks $(tsh aws ecs list-tasks \
          --cluster ${module.ecs_cluster.name} | \
          jq -r ".taskArns[0]") | \
          jq -r ".tasks[0].containers[].name"
    ECS_DESCRIBE
}
output "ecs_exec_task" {
  description = "Exec into the first running task listed."
  value       = <<-ECS_EXAMPLE
    tsh aws ecs execute-command --cluster ${module.ecs_cluster.name} \
        --container ${local.container_name} \
        --interactive \
        --command "/bin/sh" \
        --task $(tsh aws ecs list-tasks \
          --cluster ${module.ecs_cluster.name} | jq -r ".taskArns[0]")
    ECS_EXAMPLE
}
