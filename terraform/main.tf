# Network
# ==============================================================================
# Self-contained: the core has no shared VPC, so this stack owns a minimal one
# (single public subnet). The host gets a public IP + EIP; no NAT, no ALB.

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.0.0/26"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group
# ==============================================================================
# Only Caddy is public: 443 (HTTPS/MCP) and 80 (HTTP -> HTTPS redirect).
# graphiti (:8000) and the graph DB bind to the docker network / localhost and
# are never exposed here. No SSH — access is via SSM Session Manager.

resource "aws_security_group" "host" {
  name        = "${local.name_prefix}-host"
  description = "MCP host: public HTTPS via Caddy only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-host"
  }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.host.id
  description       = "HTTPS / MCP"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.host.id
  description       = "HTTP (redirect to HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# IAM
# ==============================================================================
# The instance role grants: SSM Session Manager (no SSH), read of this stack's
# secrets in Parameter Store (+ scoped KMS decrypt), and Route53 writes limited
# to the mcp zone so Caddy can solve the DNS-01 ACME challenge.

resource "aws_iam_role" "host" {
  name = "${local.name_prefix}-host"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "parameter_store" {
  name = "parameter-store"
  role = aws_iam_role.host.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.path_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "route53_dns01" {
  name = "route53-dns01"
  role = aws_iam_role.host.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${aws_route53_zone.mcp.zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "${local.name_prefix}-host"
  role = aws_iam_role.host.name
}

# Config delivery (SSM String params)
# ==============================================================================
# Platform config, pulled by the host at boot and re-pulled via `make deploy`
# (refresh.sh) without replacing the instance. Service payloads are delivered
# the same way by each service's module. Static files are read raw (their
# ${VAR} survive for compose runtime); Caddyfile and refresh.sh are rendered,
# and the Caddyfile rides encrypted (it embeds the bearer tokens).

resource "aws_ssm_parameter" "config" {
  for_each = local.config_files

  name  = "/${local.path_prefix}/config/${each.key}"
  type  = each.key == "caddy/Caddyfile" ? "SecureString" : "String"
  value = each.value
}

# Compute
# ==============================================================================
# arm64 AL2023 host; graph data on a separate EBS volume so it survives instance
# replacement. IMDS hop limit 2 so the Caddy container can assume the role for
# Route53 DNS-01. Config/secrets are fetched from SSM by user_data (cloud-init).

resource "aws_instance" "host" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name
  user_data              = local.user_data

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # most_recent AMI data means a newer AL2023 release would otherwise
  # force-replace the host on the next apply. Pin to the running AMI and
  # recreate consciously (taint) when a refresh is wanted.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${local.name_prefix}-host"
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.name_prefix}-data"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf" # appears as /dev/nvme1n1 on Nitro
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.host.id
}

resource "aws_eip" "host" {
  domain   = "vpc"
  instance = aws_instance.host.id

  tags = {
    Name = "${local.name_prefix}-host"
  }
}

