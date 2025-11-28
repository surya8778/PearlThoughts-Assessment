terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "strapi-terraform-state"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC
resource "aws_vpc" "strapi_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "strapi-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "strapi_igw" {
  vpc_id = aws_vpc.strapi_vpc.id

  tags = {
    Name = "strapi-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public_subnets" {
  count                   = 2
  vpc_id                  = aws_vpc.strapi_vpc.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "strapi-public-${count.index + 1}"
  }
}

# Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.strapi_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.strapi_igw.id
  }

  tags = {
    Name = "strapi-public-rt"
  }
}

# Route Table Associations
resource "aws_route_table_association" "public_rta" {
  count          = 2
  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

# Security Group
resource "aws_security_group" "strapi_sg" {
  name        = "strapi-security-group"
  description = "Security group for Strapi CMS"
  vpc_id      = aws_vpc.strapi_vpc.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "strapi-sg"
  }
}

# RDS PostgreSQL Database
resource "aws_db_instance" "strapi_db" {
  identifier             = "strapi-db"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "13.7"
  username               = var.db_username
  password               = var.db_password
  db_name                = "strapi"
  db_subnet_group_name   = aws_db_subnet_group.strapi_db_subnet.name
  vpc_security_group_ids = [aws_security_group.strapi_db_sg.id]
  parameter_group_name   = "default.postgres13"
  skip_final_snapshot    = true
  publicly_accessible    = false
  storage_encrypted      = true

  tags = {
    Name = "strapi-database"
  }
}

# Database Subnet Group
resource "aws_db_subnet_group" "strapi_db_subnet" {
  name       = "strapi-db-subnet-group"
  subnet_ids = aws_subnet.public_subnets[*].id

  tags = {
    Name = "strapi-db-subnet-group"
  }
}

# Database Security Group
resource "aws_security_group" "strapi_db_sg" {
  name        = "strapi-database-sg"
  description = "Security group for Strapi database"
  vpc_id      = aws_vpc.strapi_vpc.id

  ingress {
    description     = "PostgreSQL"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.strapi_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "strapi-database-sg"
  }
}

# S3 Bucket for Media Storage
resource "aws_s3_bucket" "strapi_media" {
  bucket = var.s3_bucket_name

  tags = {
    Name = "strapi-media-bucket"
  }
}

resource "aws_s3_bucket_acl" "strapi_media_acl" {
  bucket = aws_s3_bucket.strapi_media.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "strapi_media_versioning" {
  bucket = aws_s3_bucket.strapi_media.id
  versioning_configuration {
    status = "Enabled"
  }
}

# IAM Role for EC2
resource "aws_iam_role" "strapi_ec2_role" {
  name = "strapi-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for S3 Access
resource "aws_iam_policy" "strapi_s3_policy" {
  name        = "strapi-s3-policy"
  description = "Policy for Strapi to access S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.strapi_media.arn,
          "${aws_s3_bucket.strapi_media.arn}/*"
        ]
      }
    ]
  })
}

# Attach policies to role
resource "aws_iam_role_policy_attachment" "strapi_s3_attachment" {
  role       = aws_iam_role.strapi_ec2_role.name
  policy_arn = aws_iam_policy.strapi_s3_policy.arn
}

resource "aws_iam_instance_profile" "strapi_ec2_profile" {
  name = "strapi-ec2-profile"
  role = aws_iam_role.strapi_ec2_role.name
}

# EC2 Instance for Strapi
resource "aws_instance" "strapi_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.ec2_instance_type
  key_name               = aws_key_pair.strapi_key.key_name
  vpc_security_group_ids = [aws_security_group.strapi_sg.id]
  subnet_id              = aws_subnet.public_subnets[0].id
  iam_instance_profile   = aws_iam_instance_profile.strapi_ec2_profile.name

  user_data = templatefile("${path.module}/scripts/user-data.sh", {
    db_host     = aws_db_instance.strapi_db.address
    db_name     = aws_db_instance.strapi_db.name
    db_username = aws_db_instance.strapi_db.username
    db_password = aws_db_instance.strapi_db.password
    s3_bucket   = aws_s3_bucket.strapi_media.bucket
    aws_region  = var.aws_region
  })

  tags = {
    Name = "strapi-server"
  }

  depends_on = [aws_db_instance.strapi_db]
}

# SSH Key Pair
resource "aws_key_pair" "strapi_key" {
  key_name   = "strapi-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

# Elastic IP
resource "aws_eip" "strapi_eip" {
  instance = aws_instance.strapi_server.id
  domain   = "vpc"

  tags = {
    Name = "strapi-eip"
  }
}

# Application Load Balancer
resource "aws_lb" "strapi_alb" {
  name               = "strapi-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.strapi_sg.id]
  subnets            = aws_subnet.public_subnets[*].id

  tags = {
    Name = "strapi-alb"
  }
}

# Target Group
resource "aws_lb_target_group" "strapi_tg" {
  name     = "strapi-tg"
  port     = 1337
  protocol = "HTTP"
  vpc_id   = aws_vpc.strapi_vpc.id

  health_check {
    path                = "/_health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Listener
resource "aws_lb_listener" "strapi_listener" {
  load_balancer_arn = aws_lb.strapi_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.strapi_tg.arn
  }
}

# Target Group Attachment
resource "aws_lb_target_group_attachment" "strapi_tg_attachment" {
  target_group_arn = aws_lb_target_group.strapi_tg.arn
  target_id        = aws_instance.strapi_server.id
  port             = 1337
}

# Outputs
output "strapi_url" {
  value = "http://${aws_lb.strapi_alb.dns_name}"
}

output "database_endpoint" {
  value = aws_db_instance.strapi_db.address
}

output "ec2_public_ip" {
  value = aws_eip.strapi_eip.public_ip
}

output "s3_bucket_name" {
  value = aws_s3_bucket.strapi_media.bucket
}
