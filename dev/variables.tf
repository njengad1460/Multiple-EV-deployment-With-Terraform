variable "vpc_cidr" {
  description = "The CIDR block for the production vpc VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "vpc_name" {
  description = "The name tag for the VPC"
  type        = string
  default     = "demo-vpc"
}

variable "instance_type" {
  description = "The type of EC2 instance to launch"
  type        = string
  default     = "t3.micro"
}

variable "public_subnet_config" {
  description = "Map of subnet names to their index for CIDR calculation"
  type        = map(number)
  default     = {
    "public_subnet_1" = 1
    "public_subnet_2" = 2
  }
}

# adding Auto-Scalling Group with minimum and maximim numbers of EC2
variable "min_size" {
  description = "minimum number of EC2 instances in an Auto Scalling Group"
  type = number
  default = 1
}

variable "max_size" {
  description = "Maxmim number of ec2 instance per ASG"
  type = number
  default = 2
}