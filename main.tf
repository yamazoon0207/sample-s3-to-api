# ECSクラスター
resource "aws_ecs_cluster" "main" {
  name = "json-to-yaml-converter"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# CloudWatch Logsロググループ
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/json-to-yaml-converter"
  retention_in_days = 7
}

# ECSタスク実行ロール
resource "aws_iam_role" "ecs_task_execution" {
  name = "json-to-yaml-converter-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECSタスクロール
resource "aws_iam_role" "ecs_task" {
  name = "json-to-yaml-converter-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket_name}",
          "arn:aws:s3:::${var.s3_bucket_name}/*"
        ]
      }
    ]
  })
}

# セキュリティグループ
resource "aws_security_group" "ecs_task" {
  name        = "json-to-yaml-converter-task"
  description = "Security group for JSON to YAML converter ECS tasks"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECSタスク定義
resource "aws_ecs_task_definition" "main" {
  family                   = "json-to-yaml-converter"
  requires_compatibilities = ["FARGATE"]
  network_mode            = "awsvpc"
  cpu                     = var.task_cpu
  memory                  = var.task_memory
  execution_role_arn      = aws_iam_role.ecs_task_execution.arn
  task_role_arn          = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "converter"
      image     = var.container_image
      essential = true

      environment = [
        {
          name  = "S3_BUCKET"
          value = var.s3_bucket_name
        },
        {
          name  = "API_ENDPOINT"
          value = var.api_endpoint
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# EventBridgeスケジューラーのIAMロール
resource "aws_iam_role" "scheduler" {
  name = "json-to-yaml-converter-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "ecs-task-execution"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask"
        ]
        Resource = [aws_ecs_task_definition.main.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = [
          aws_iam_role.ecs_task.arn,
          aws_iam_role.ecs_task_execution.arn
        ]
      }
    ]
  })
}

# EventBridgeスケジュール
resource "aws_scheduler_schedule" "main" {
  name        = "json-to-yaml-converter-schedule"
  description = "Schedule for running JSON to YAML converter task"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = var.schedule_expression

  target {
    arn      = aws_ecs_cluster.main.arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.main.arn
      launch_type         = "FARGATE"

      network_configuration {
        subnets          = var.subnet_ids
        security_groups  = [aws_security_group.ecs_task.id]
        assign_public_ip = false
      }
    }
  }
}
