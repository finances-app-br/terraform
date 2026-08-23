# finance_app BFF — infrastructure

Terraform for the BFF: **Cloudflare** (DNS + proxy) in front of an **API Gateway**
HTTP API that invokes a **Lambda** function backed by **Aurora Serverless v2**
(PostgreSQL, reached through the **RDS Data API**).

Providers (pinned in [`versions.tf`](versions.tf), latest at time of writing):

| Provider                 | Version  |
| ------------------------ | -------- |
| `hashicorp/aws`          | `~> 6.0` |
| `cloudflare/cloudflare`  | `~> 5.0` |
| `hashicorp/archive`      | `~> 2.6` |
| `hashicorp/null`         | `~> 3.2` |

## What it provisions

- **Aurora Serverless v2** (`aurora-postgresql`) cluster with the **Data API**
  enabled, encrypted storage, automated backups, and RDS-managed master
  credentials in Secrets Manager. Capacity scales `min`→`max` ACUs and, at
  `aurora_min_capacity = 0`, pauses entirely while idle.
- A **private VPC** (no internet gateway, no NAT) with a subnet group across two
  AZs, purely because a cluster must live in one — nothing reaches it over the
  network.
- The **schema migration**: a `null_resource` runs `npm run migrate` in
  [`../app`](../app) once the cluster answers, creating the four entity tables.
- **Lambda** (`arm64`, Node.js runtime) with a least-privilege IAM role scoped to
  the Data API on this cluster + its master secret, and a CloudWatch log group
  with retention.
- **API Gateway** HTTP API with a `POST /graphql` route, CORS, `$default` stage,
  and an optional JWT authorizer.
- **ACM** certificate (DNS-validated via Cloudflare) + API Gateway custom domain.
- **Cloudflare** DNS: the ACM validation record and a proxied `CNAME` for the API.

The Lambda bundle is built automatically: a `null_resource` runs
`npm ci && npm run build` in [`../app`](../app) whenever its sources change, and
the result is zipped for deployment.

### Why the Data API

The Data API is a regular AWS endpoint, so the Lambda talks to Aurora **without
being attached to the VPC**: no ENI cold starts, no NAT gateway, and no
connection pool for a bursty function to exhaust. That is also what makes
scale-to-zero practical — a paused cluster answers the first statement with
`DatabaseResumingException`, which the BFF retries while it wakes up.

## Prerequisites

- Terraform ≥ 1.9, Node.js ≥ 22, and the AWS CLI authenticated
  (`aws sts get-caller-identity` should work).
- A Cloudflare zone for your domain and an API token with **DNS edit** on it.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit values
export TF_VAR_cloudflare_api_token=...          # keep the token out of the file

terraform init
terraform apply
```

After apply, use the **`graphql_url`** output as the Flutter app's sync endpoint.

### Cloudflare SSL/TLS mode

The public record is **proxied** (orange cloud). Set the zone's SSL/TLS mode to
**Full** (or **Full (strict)**) so Cloudflare trusts the API Gateway certificate
on the origin. The ACM validation record is intentionally **not** proxied.

### Enabling the JWT authorizer (recommended for production)

Uncomment `jwt_authorizer` in `terraform.tfvars` with your OIDC issuer and
audience (e.g. an Amazon Cognito user pool). The `/graphql` route then requires a
`Authorization: Bearer <token>` header and the BFF uses the token's `sub` claim
as the user id. Without it, the BFF trusts the `x-user-id` header — **dev only**.

## Deploying without a domain

For a first deploy you can skip Cloudflare/ACM:

```bash
terraform apply -var enable_custom_domain=false
```

The `graphql_url` output is then the raw `*.execute-api` URL. Note: the Cloudflare
provider still validates `cloudflare_api_token` at init, so pass any
correctly-formatted token (40 chars of `[A-Za-z0-9_-]`) or export
`CLOUDFLARE_API_TOKEN`, even when the domain is disabled.

## Key variables

| Variable                          | Default           | Notes                                   |
| --------------------------------- | ----------------- | --------------------------------------- |
| `project_name`                    | `finance-app-bff` | Resource name prefix.                   |
| `aws_region`                      | `us-east-1`       |                                         |
| `aurora_engine_version`           | `16.6`            | Scale-to-zero needs 16.3+/15.7+/14.12+. |
| `aurora_database_name`            | `finance`         | Database the BFF queries.               |
| `aurora_min_capacity`             | `0`               | `0` pauses the cluster when idle.       |
| `aurora_max_capacity`             | `2`               | Upper ACU bound.                        |
| `aurora_seconds_until_auto_pause` | `300`             | Idle time before scaling to zero.       |
| `aurora_deletion_protection`      | `false`           | `true` blocks `terraform destroy`.      |
| `aurora_vpc_cidr`                 | `10.42.0.0/16`    | Private VPC hosting the cluster.        |
| `lambda_runtime`                  | `nodejs22.x`      | Bump to `nodejs24.x` when available.    |
| `enable_custom_domain`            | `true`            | Cloudflare + ACM + custom domain.       |
| `domain_name`                     | `""`              | e.g. `api.finance.example.com`.         |
| `cloudflare_zone_id`              | `""`              | Zone owning `domain_name`.              |
| `cors_allow_origins`              | `["*"]`           | Restrict in production.                 |
| `jwt_authorizer`                  | `null`            | `{ issuer, audiences }` to enable auth. |

## Running the migration by hand

The schema script is idempotent, so it can be re-run at any time — for example
after editing `../app/src/data/auroraSchema.ts`:

```bash
cd ../app
AURORA_CLUSTER_ARN=$(terraform -chdir=../terraform output -raw aurora_cluster_arn) \
AURORA_SECRET_ARN=$(terraform -chdir=../terraform output -raw aurora_secret_arn) \
AURORA_DATABASE_NAME=$(terraform -chdir=../terraform output -raw aurora_database_name) \
npm run migrate
```

Ad-hoc SQL against the cluster goes through the Data API too — no bastion needed:

```bash
aws rds-data execute-statement \
  --resource-arn "$(terraform output -raw aurora_cluster_arn)" \
  --secret-arn   "$(terraform output -raw aurora_secret_arn)" \
  --database     "$(terraform output -raw aurora_database_name)" \
  --sql "SELECT count(*) FROM transactions"
```

## Destroy

```bash
terraform destroy
```

With `aurora_skip_final_snapshot = false` (the default) a final snapshot is taken
before the cluster goes away; `aurora_deletion_protection = true` refuses the
destroy outright.
