# Aurora Serverless v2 (PostgreSQL) — the sync store, reached through the RDS
# Data API. The Data API is a regular AWS endpoint, so the Lambda stays outside
# the VPC: no ENIs, no cold-start penalty, no connection pool to exhaust, and the
# cluster is free to scale down to zero ACUs between syncs.
#
# The cluster still needs a VPC to live in. Nothing reaches it over the network,
# so this is a minimal private-only VPC: no internet gateway, no NAT.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "aurora" {
  cidr_block           = var.aurora_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-aurora" }
}

# One subnet per AZ — Aurora requires a subnet group spanning at least two.
resource "aws_subnet" "aurora" {
  count = var.aurora_subnet_count

  vpc_id            = aws_vpc.aurora.id
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = cidrsubnet(var.aurora_vpc_cidr, 8, count.index)

  tags = { Name = "${var.project_name}-aurora-${count.index}" }
}

resource "aws_db_subnet_group" "aurora" {
  name       = "${var.project_name}-aurora"
  subnet_ids = aws_subnet.aurora[*].id
}

# Deliberately empty: the cluster is only ever addressed through the Data API.
# Attach an ingress rule here if you later need psql access from a bastion.
resource "aws_security_group" "aurora" {
  name        = "${var.project_name}-aurora"
  description = "Aurora Serverless v2 cluster — Data API only, no network ingress."
  vpc_id      = aws_vpc.aurora.id

  tags = { Name = "${var.project_name}-aurora" }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.project_name}-aurora"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned" # Serverless v2 runs on the provisioned engine.
  engine_version     = var.aurora_engine_version
  database_name      = var.aurora_database_name

  master_username = var.aurora_master_username
  # RDS creates and rotates the master secret in Secrets Manager, so no password
  # ever lands in the Terraform state. Its ARN is what the Data API authenticates
  # with.
  manage_master_user_password = true

  # The Data API ("HTTP endpoint") is what lets the Lambda talk to the cluster
  # without a VPC attachment.
  enable_http_endpoint = true

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  serverlessv2_scaling_configuration {
    # min_capacity = 0 lets the cluster pause entirely when idle; the first
    # statement after a pause wakes it (the BFF retries DatabaseResumingException).
    min_capacity             = var.aurora_min_capacity
    max_capacity             = var.aurora_max_capacity
    seconds_until_auto_pause = var.aurora_seconds_until_auto_pause
  }

  storage_encrypted       = true
  backup_retention_period = var.aurora_backup_retention_days
  copy_tags_to_snapshot   = true
  deletion_protection     = var.aurora_deletion_protection

  skip_final_snapshot       = var.aurora_skip_final_snapshot
  final_snapshot_identifier = var.aurora_skip_final_snapshot ? null : "${var.project_name}-aurora-final"

  lifecycle {
    # The engine auto-upgrades minor versions; don't fight it on the next apply.
    ignore_changes = [engine_version]
  }
}

resource "aws_rds_cluster_instance" "aurora" {
  identifier          = "${var.project_name}-aurora-1"
  cluster_identifier  = aws_rds_cluster.aurora.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.aurora.engine
  engine_version      = aws_rds_cluster.aurora.engine_version
  publicly_accessible = false
}

# Applies the sync schema (see the BFF's src/data/auroraSchema.ts) once the cluster
# can answer statements. The script is idempotent, so re-runs are harmless.
resource "null_resource" "aurora_migrate" {
  triggers = {
    cluster = aws_rds_cluster.aurora.id
    schema  = filesha1("${local.bff_path}/src/data/auroraSchema.ts")
  }

  provisioner "local-exec" {
    working_dir = local.bff_path
    command     = "npm run migrate"

    environment = {
      AWS_REGION           = var.aws_region
      AURORA_CLUSTER_ARN   = aws_rds_cluster.aurora.arn
      AURORA_SECRET_ARN    = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
      AURORA_DATABASE_NAME = aws_rds_cluster.aurora.database_name
    }
  }

  # null_resource.build already ran `npm ci`, which installs the tsx runner.
  depends_on = [
    aws_rds_cluster_instance.aurora,
    null_resource.build,
  ]
}
