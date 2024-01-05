resource "aws_ecs_cluster" "monitor" {
  name = "monitor"
}

resource "aws_security_group" "monitor" {
  name   = "ecs-instance-monitor"
  vpc_id = "${aws_vpc.main.id}"

#  ingress {
#    from_port   = 22
#    to_port     = 22
#    protocol    = "TCP"
#    cidr_blocks = ["0.0.0.0/0"]
#  }

#  ingress {
#    from_port   = 3000
#    to_port     = 3000
#    protocol    = "TCP"
#    cidr_blocks = ["0.0.0.0/0"]
#  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "prometheus_task_role" {
  name               = "prometheus_task_role"
  assume_role_policy = "${data.aws_iam_policy_document.assume_ecs.json}"
}

resource "aws_iam_policy" "prometheus_task_role_policy" {
  name = "prometheus_task_role_policy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PrometheusTaskRolePolicy",
      "Effect": "Allow",
      "Action": [
        "ecs:ListClusters",
        "ecs:ListTasks",
        "ec2:DescribeInstances",
        "ecs:DescribeContainerInstances",
        "ecs:DescribeTasks",
        "ecs:DescribeTaskDefinition"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "prometheus_task_role_attachment" {
  role       = "${aws_iam_role.prometheus_task_role.name}"
  policy_arn = aws_iam_policy.prometheus_task_role_policy.arn
}

#
#resource "aws_iam_instance_profile" "ecs_instance_monitor" {
#  name = "ecsInstanceMonitor"
#  role = "${aws_iam_role.ecs_instance_monitor.name}"
#}
#
resource "aws_iam_role" "prometheus_task_execution_role" {
  name               = "prometheus_task_execution_role"
  assume_role_policy = "${data.aws_iam_policy_document.assume_ecs.json}"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_monitor_access_ecs" {
  role       = "${aws_iam_role.prometheus_task_execution_role.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
#
#resource "aws_iam_role_policy_attachment" "ecs_instance_monitor_access_ec2" {
#  role       = "${aws_iam_role.ecs_instance_monitor.name}"
#  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
#}
#
#resource "aws_instance" "monitor" {
#  ami                         = "${data.aws_ssm_parameter.ecs_instance_ami.value}"
#  instance_type               = "t2.micro"
#  associate_public_ip_address = true
#  iam_instance_profile        = "${aws_iam_instance_profile.ecs_instance_monitor.name}"
#  subnet_id                   = "${aws_subnet.public.id}"
#  vpc_security_group_ids      = ["${aws_security_group.monitor.id}"]
#  key_name                    = "${var.ssh_key}"
#
#  user_data = <<EOF
##!/bin/bash
#
#echo ECS_CLUSTER=monitor >> /etc/ecs/ecs.config
#EOF
#
#  tags = {
#    Name = "monitor"
#  }
#}

resource "aws_ecs_task_definition" "prometheus_task_definition" {
  family                   = "prometheus"
  task_role_arn            = aws_iam_role.prometheus_task_role.arn
  execution_role_arn       = aws_iam_role.prometheus_task_execution_role.arn
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  network_mode             = "awsvpc"

  volume {
    name = "config"
  }

  container_definitions = <<EOF
[
  {
    "name": "prometheus",
    "image": "tkgregory/prometheus-with-remote-configuration",
    "cpu": 256,
    "memory": 512,
    "essential": true,
    "portMappings": [
      {
        "containerPort": 9090,
        "hostPort": 9090
      }
    ],
    "environment": [
        {
            "name": "CONFIG_LOCATION",
            "value": "https://tomgregory-cloudformation-resources.s3-eu-west-1.amazonaws.com/prometheus.yml"
        }
    ],
    "mountPoints": [
        {
            "sourceVolume": "config",
            "containerPath": "/output",
            "readOnly": false
        }
    ]
  }
,
  {
    "name": "prometheus-ecs-discovery",
    "image": "tkgregory/prometheus-ecs-discovery",
    "cpu": 256,
    "memory": 512,
    "essential": true,
    "environment": [
        {
            "name": "AWS_REGION",
            "value": "ap-northeast-1"
        }
    ],
    "mountPoints": [
        {
            "sourceVolume": "config",
            "containerPath": "/output",
            "readOnly": false
        }
    ],
    "command": ["-config.write-to=/output/ecs_file_sd.yml"]
  }
]
EOF
}

resource "aws_ecs_service" "prometheus_service" {
  name            = "prometheus"
  cluster         = "${aws_ecs_cluster.monitor.id}"
  task_definition = "${aws_ecs_task_definition.prometheus_task_definition.arn}"
  desired_count   = "1"
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.monitor.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_task_definition" "sample-metrics-application-task" {
  family       = "sample-metrics-application-task"
  cpu          = 256
  memory       = 512
  network_mode = "awsvpc"

  container_definitions = <<EOF
[
  {
    "name": "sample-metrics-application",
    "image": "tkgregory/sample-metrics-application",
    "cpu": 128,
    "memory": 256,
    "portMappings": [
      {
        "containerPort": 8080,
        "hostPort": 8080
      }
    ],
    "dockerLabels": {
      "PROMETHEUS_EXPORTER_PORT": "8080",
      "PROMETHEUS_EXPORTER_PATH": "/actuator/prometheus"
    }
  }
,
  {
    "name": "ecs-container-exporter",
    "image": "raags/ecs-container-exporter:latest",
    "portMappings": [
      {
        "hostPort": 9545,
        "protocol": "tcp",
        "containerPort": 9545
      }
    ],
    "command": [],
    "cpu": 128,
    "memory": 256,
    "dockerLabels": {
      "PROMETHEUS_EXPORTER_PORT": "9545"
    }
  }
]
EOF
}

resource "aws_security_group" "app_sg" {
  name   = "app-sg"
  vpc_id = "${aws_vpc.main.id}"

  ingress {
    from_port = 8080
    to_port   = 8080
    protocol  = "TCP"
    #    security_groups = ["${aws_security_group.monitor.id}"]

    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "service1" {
  name            = "service1"
  cluster         = aws_ecs_cluster.monitor.id
  task_definition = aws_ecs_task_definition.sample-metrics-application-task.id
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.app_sg.id]
    assign_public_ip = true
  }
}

#resource "aws_ecs_task_definition" "grafana" {
#  family = "grafana"
#
#  container_definitions = <<EOF
#[
#  {
#    "name": "grafana",
#    "image": "grafana/grafana",
#    "cpu": 10,
#    "memory": 128,
#    "essential": true,
#    "portMappings": [
#      {
#        "containerPort": 3000,
#        "hostPort": 3000
#      }
#    ]
#  }
#]
#EOF
#}
#
#resource "aws_ecs_service" "grafana" {
#  name                               = "grafana"
#  cluster                            = "${aws_ecs_cluster.monitor.id}"
#  task_definition                    = "${aws_ecs_task_definition.grafana.arn}"
#  desired_count                      = "1"
#  deployment_minimum_healthy_percent = 0
#  deployment_maximum_percent         = 100
#}
