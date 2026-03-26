# --- Networking ---

# data sources... this are the data am fetching from my aws account


data "aws_region" "current" {}

data "aws_availability_zones" "available"{
    state = "available"
}

data "aws_ami" "ubuntu_22_04"{
    most_recent = true
    filter {
      name = "name"
      values = [ "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" ]
    }
    owners = [ "099720109477" ]
}


# VPC & GATEWAY 
resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr # ie for prod 10.1.0.0/16
  enable_dns_hostnames = true
  tags ={
    Name = "prod-vpc"
    Environment = "production"
    ManagedBy = "Terraform"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "prod-igw"
  }
}


# Dynamic Subnetting (spread across AZs)

resource "aws_subnet" "public_subnets" {
  for_each = var.public_subnet_config   # this is a loop,,, looks for all az
  vpc_id = aws_vpc.vpc.id               # this tells the vpc where subnets belong to
  cidr_block = cidrsubnet(aws_vpc.vpc.cidr_block, 8, each.value) # this calculate the IP range 
  # cidrsubnet(...): A built-in function that carves a large network into smaller pieces
  # aws_vpc.vpc.cidr_block: Starts with your main VPC range (e.g., 10.1.0.0/16)
  # 8: Adds 8 bits to the prefix (changing the /16 to a /24)
  # each.value: Uses the number from your map to set the subnet ID Lap 0 :10.1.0.0/24 Lap 1: 10.1.1.0/24
  availability_zone = tolist(data.aws_availability_zones.available.names)[each.value]
  # data.aws_availability_zones...: Grabs the list of real AZs in your region (e.g., ["us-east-1a", "us-east-1b", "us-east-1c"]).
  # tolist(...): Converts that data into a list format.
    # [each.value]: Uses the index number to pick an AZ.
    # If each.value is 0, it picks the first AZ (us-east-1a).
    # If each.value is 1, it picks the second AZ (us-east-1b).
  map_public_ip_on_launch = true

  tags = {
    Name = "prod-public-${each.key}"
    # ${each.key}: This is string interpolation. It inserts the key from your map into the name.
    # prod-public-az1, the next prod-public-az2
    Environment = "production"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "Production-Route-Talbe"
  }
}

resource "aws_route_table_association" "public_association" {
  for_each = aws_subnet.public_subnets
  subnet_id = each.value.id
  route_table_id = aws_route_table.public_rt.id
}

# Security
# ALB security grouup

resource "aws_security_group" "alb-sg" {
    name = "prod-alb-sg"  
    description = "Production Load balancer security group"
    vpc_id = aws_vpc.vpc.id

    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = [ "0.0.0.0/0" ]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = [ "0.0.0.0/0" ]
    }
}

# security group for EC2

resource "aws_security_group" "web_traffic" {
  name = "prod-web-sg"
  description = "security group for web server"
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [ aws_security_group.alb-sg.id ]
  }
  egress {
    from_port = 0
    to_port = 0 
    protocol = "-1"
    cidr_blocks = [ "0.0.0.0/0" ]
  }
}

# compute and scalling
# Lauch template
resource "aws_launch_template" "web_lt" {
  name_prefix = "prod-web-server"
  image_id = "data.aws_ami.ubuntu_22_04.id"
  instance_type = var.instance_type # t3.micro

  network_interfaces {
    associate_public_ip_address = true
    security_groups = [ aws_security_group.web_traffic.id ]
  }
  user_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y apache2
              systemctl start apache2
              systemctl enable apache2
              echo "<h1>PROD ENVIRONMENT | Host: $(hostname -f)</h1>" > /var/www/html/index.html
              EOF
  )
}

# auto scalling group
 resource "aws_autoscaling_group" "web_asg" {
   name = "prod-asg"
   vpc_zone_identifier = [ for s in aws_subnet.public_subnets : s.id ]
   target_group_arns = [ aws_lb_target_group.web_tg.arn ]
   health_check_type = "ELB"

   min_size = var.min_size
   max_size = var.max_size
   desired_capacity = var.min_size

   launch_template {
     id = aws_launch_template.web_lt.id
     version = "$Latest"
   }
   tag {
     key = "Name"
     value = "prod-web-instance"
     propagate_at_launch = true
   }
   tag {
     key = "Environment"
     value = "production"
     propagate_at_launch = true
   }
 }

 # Trafic managment ( load balancing)

 resource "aws_lb" "web_alb" {
   name = "prod-web-alb"
   internal = false
   load_balancer_type = "application"
   security_groups = [ aws_security_group.alb-sg.id ]
   subnets = [ for s in aws_subnet.public_subnets : s.id ]
   tags = {
     Name = "prod-web-alb"
   }
 }


 # Target Group with Health check

resource "aws_lb_target_group" "web_tg" {
  name     = "prod-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15 # Faster checks for Prod
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}