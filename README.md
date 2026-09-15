# finances — infrastructure

Terraform for the finances platform: **Cloudflare** (DNS, proxy, zone hardening
and edge rules) in front of **three independent API Gateway + Lambda stacks**,
one of which — the GraphQL sync BFF — is backed by **Aurora Serverless v2**
(PostgreSQL, reached through the **RDS Data API**), plus the **static marketing
site** served from S3 at the zone apex.

Providers (pinned in [`versions.tf`](versions.tf), latest at time of writing):

| Provider                 | Version  |
| ------------------------ | -------- |
| `hashicorp/aws`          | `~> 6.0` |
| `cloudflare/cloudflare`  | `~> 5.0` |
| `hashicorp/archive`      | `~> 2.6` |
| `hashicorp/null`         | `~> 3.2` |

## Three stacks from one map

[`locals.tf`](locals.tf) holds a `services` map. Every entry gets **its own** API
Gateway, Lambda, IAM role, CloudWatch log group, ACM certificate and Cloudflare
record — nothing is shared:

| Service | Domain                  | Route            | Code                    | Aurora |
| ------- | ----------------------- | ---------------- | ----------------------- | ------ |
| `web`   | `web_domain_name`       | `$default`       | generated placeholder   | no     |
| `api`   | `api_domain_name`       | `$default`       | generated placeholder   | no     |
| `bff`   | `bff_domain_name`       | `POST /graphql`  | built from `app-bff/`   | yes    |

Only `bff` has `aurora_access = true`, so only its IAM role carries the RDS Data
API and Secrets Manager statements, and only its function gets the `AURORA_*`
environment variables. **A bug on another surface cannot reach finance data.**

`web` and `api` have no application yet: they run a stub handler that answers
`200 {"service":"…","status":"placeholder"}`, which is enough to verify the
DNS → TLS → API Gateway → Lambda chain end to end. Replace
`data.archive_file.placeholder` in [`lambda.tf`](lambda.tf) with a real build
when the portal lands; adding a fourth surface means adding an entry to
`services` and a `*_domain_name` / `*_cors_allow_origins` variable pair.

The zone apex is **not** available to `web`: it belongs to the static site
below, and a validation rejects `web_domain_name = site_domain_name`.

## Static site

The landing page and institutional pages (`site` repository — plain
HTML/CSS/JS built with Parcel) are served from S3 through Cloudflare. It has no
API Gateway or Lambda, so it lives outside the `services` map, in
[`site.tf`](site.tf) plus a section of [`cloudflare.tf`](cloudflare.tf) and
[`iam.tf`](iam.tf). It is created when `site_domain_name` is set (and
`enable_custom_domain` is true).

```
GitHub Actions ──(OIDC)──► site deploy role ──► S3 sync + Cloudflare purge
Browser ──HTTPS──► Cloudflare edge (proxied) ──HTTP──► S3 website endpoint
                   (cache, www redirect, headers)       (Cloudflare IPs only)
```

Things that look optional but are not:

- **The bucket name is `site_domain_name`.** Cloudflare forwards the original
  `Host` header and the S3 website endpoint routes by hostname.
- **Reads are restricted to Cloudflare's IP ranges** by the bucket policy, so the
  records are always proxied. Opening the bucket would bypass every edge rule.
- **SSL is `flexible` for the site hosts only**, through a Configuration Rule.
  The website endpoint has no HTTPS listener, while the zone stays `strict` for
  the API Gateway origins. Never lower the zone-wide `cloudflare_ssl_mode` to
  fix a site 525/526 — it would open a cleartext leg for api/bff.
- **Every rule is scoped to the site's hostnames** (`local.site_hosts_expression`
  / `local.site_apex_expression`), so cache TTLs never apply to API responses.
- **Rulesets are zone entrypoints: one per phase per zone.** This stack owns the
  `http_config_settings`, `http_request_cache_settings`,
  `http_request_dynamic_redirect` and `http_response_headers_transform`
  entrypoints. A new rule in any of those phases — for any hostname — goes into
  the existing resource, not a new ruleset or the dashboard.

Cache: content-hashed assets get 30 days at the edge and in the browser; pages
(`.html` and directory URLs like `/contato/`) get 1 hour at the edge and 5
minutes in the browser.

### Deploying content

Terraform never uploads the site. On every push to `site_github_deploy_branch`,
the site repository's workflow builds it, assumes the **`site_deploy_role_arn`**
role through GitHub OIDC, syncs `dist/` into the bucket and purges **only the
page URLs** from Cloudflare — never the whole zone, which api/bff share. The
role trusts exactly `repo:<site_github_repository>:ref:refs/heads/<branch>`; a
mismatch makes the workflow fail with `AccessDenied`.

Repository secrets on the site repository:

```bash
gh secret set AWS_DEPLOY_ROLE_ARN --repo finances-app-br/site --body "$(terraform output -raw site_deploy_role_arn)"
gh secret set CF_ZONE_ID          --repo finances-app-br/site --body "<zone id>"
gh secret set CF_API_TOKEN        --repo finances-app-br/site   # token with Zone:Cache Purge only
```

An AWS account holds a single GitHub OIDC provider. `create_github_oidc_provider`
defaults to `false`, which looks the existing one up; set it to `true` only in
an account that has none.

## What it provisions

- **Aurora Serverless v2** (`aurora-postgresql`) cluster with the **Data API**
  enabled, encrypted storage, automated backups, and RDS-managed master
  credentials in Secrets Manager. Capacity scales `min`→`max` ACUs and, at
  `aurora_min_capacity = 0`, pauses entirely while idle.
- A **private VPC** (no internet gateway, no NAT) with a subnet group across two
  AZs, purely because a cluster must live in one — nothing reaches it over the
  network.
- The **schema migration**: a `null_resource` runs `npm run migrate` in
  `bff_source_dir` once the cluster answers, creating the four entity tables.
- **Lambda** per service (`arm64`, Node.js runtime) with a least-privilege IAM
  role, optional X-Ray active tracing, optional reserved concurrency, and a
  CloudWatch log group with retention.
- **API Gateway** HTTP API per service, with per-stage **throttling**, optional
  CORS, a `$default` stage, and an optional JWT authorizer on the BFF.
- **ACM** certificates (DNS-validated via Cloudflare) + API Gateway custom
  domains.
- **S3** website bucket for the static site (versioned, encrypted, readable
  only from Cloudflare) and the **GitHub OIDC deploy role** that syncs it.
- **Cloudflare** DNS: the ACM validation records, a proxied `CNAME` per service
  and for the site apex/www, the site's cache/redirect/header/SSL rules, plus
  optional zone-wide hardening (SSL mode, HTTPS redirect, HSTS, DNSSEC, CAA).

The BFF bundle is built automatically: a `null_resource` runs
`npm ci && npm run build` in `bff_source_dir` whenever its sources change, and
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
- A Cloudflare zone for your domain and an API token scoped to it with
  **DNS: Edit**, plus **Zone Settings: Edit** if
  `manage_cloudflare_zone_security = true`, plus — when the site is enabled —
  **Config Rules: Edit**, **Cache Rules: Edit**, **Single Redirect: Edit** and
  **Transform Rules: Edit**. Each ruleset phase is a separate permission group.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit values
export CLOUDFLARE_API_TOKEN=...                 # keep the token out of the file

terraform init
terraform apply
```

After apply, use the **`graphql_url`** output as the Flutter app's sync endpoint;
**`service_urls`** lists the public base URL of all three services, and
**`site_deploy_role_arn`** goes into the site repository's secrets (see
[Deploying content](#deploying-content)).

## Domain hardening

`manage_cloudflare_zone_security`, `enable_dnssec` and `manage_caa_records` are
**zone-wide** — they apply to every hostname in `cloudflare_zone_id`, not just
the domains this stack creates. Leave them `false` if the zone is shared with
something Terraform does not own. Three things to know before enabling them:

- **`cloudflare_ssl_mode = "strict"`** requires a valid, publicly trusted
  certificate on the origin. API Gateway custom domains have one, so this is
  safe here. The static site is the exception and gets its own per-host
  `flexible` rule; any *other* origin added to the zone needs a certificate or a
  rule of its own, or it starts returning 526.
- **DNSSEC is not enforced until you publish the DS record at your registrar.**
  Terraform turns on signing; take the `dnssec_ds_record` output to wherever the
  domain is registered. Cloudflare's own DS is not enough on its own.
- **CAA records restrict who may issue certificates for the whole zone.** The
  `caa_issuers` default covers ACM plus the CAs Cloudflare's Universal SSL
  rotates between; dropping one can silently break edge-certificate renewal
  months later — the static site depends on that edge certificate.
  `hsts_preload` is likewise slow to undo — leave it `false` until every
  subdomain is HTTPS-only.

Cloudflare zone settings **cannot be destroyed by Terraform**: removing the
resources leaves the settings in place, so revert them in the dashboard if you
ever back this out.

### Enabling the JWT authorizer (recommended for production)

Uncomment `jwt_authorizer` in `terraform.tfvars` with your OIDC issuer and
audience (e.g. an Amazon Cognito user pool). The BFF's `/graphql` route then
requires an `Authorization: Bearer <token>` header and the BFF uses the token's
`sub` claim as the user id. Without it, the BFF trusts the `x-user-id` header —
**dev only**. The authorizer attaches to the `bff` service alone.

## Deploying without a domain

For a first deploy you can skip Cloudflare/ACM:

```bash
terraform apply -var enable_custom_domain=false
```

`service_urls` and `graphql_url` are then the raw `*.execute-api` URLs, and no
Cloudflare token is needed at all — with every `cloudflare_*` resource counted
out (the static site included), the provider is never configured.

## Cloudflare tokens across projects

The provider reads **`CLOUDFLARE_API_TOKEN`** natively, so there is no reason to
route it through `TF_VAR_cloudflare_api_token` or `terraform.tfvars`. The
`cloudflare_api_token` variable exists only as an escape hatch; leave it unset
and `providers.tf` passes `null`, which is what lets the environment win.

If you run several stacks against different Cloudflare zones, scope the token
**per directory** rather than exporting one globally from `~/.zshrc` — a token
scoped to one zone cannot damage another, and a shell-wide export defeats that.
[`direnv`](https://direnv.net) plus the macOS Keychain does this without any
secret landing in a file:

```bash
brew install direnv
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc      # once

# store this project's token in the Keychain (prompts for the value)
security add-generic-password -s cloudflare-token -a finances -w
```

Then, in this directory:

```bash
cat > .envrc <<'SH'
export CLOUDFLARE_API_TOKEN="$(security find-generic-password -s cloudflare-token -a finances -w)"
SH
direnv allow
```

`.envrc` holds only a *reference*, so it is safe to commit; the secret stays in
the Keychain and is exported only while you are inside the directory. Another
project uses the same `.envrc` with a different `-a` account name.

Without direnv, the same one-liner works as a zsh function or a small `tf`
wrapper — the point is that the token is fetched at run time and scoped to one
project, not that direnv specifically is doing it.

Give each token the narrowest scope that works — see
[Prerequisites](#prerequisites) for this stack's list. The site workflow's
`CF_API_TOKEN` is a separate token that only needs **Cache Purge**.

## Key variables

| Variable                          | Default                | Notes                                        |
| --------------------------------- | ---------------------- | -------------------------------------------- |
| `project_name`                    | `finance-app-bff`      | Resource name prefix.                        |
| `aws_region`                      | `us-east-1`            |                                              |
| `bff_source_dir`                  | `../app-bff`           | BFF checkout built into the Lambda bundle.   |
| `aurora_engine_version`           | `16.6`                 | Scale-to-zero needs 16.3+/15.7+/14.12+.      |
| `aurora_min_capacity`             | `0`                    | `0` pauses the cluster when idle.            |
| `aurora_max_capacity`             | `2`                    | Upper ACU bound.                             |
| `aurora_seconds_until_auto_pause` | `300`                  | Idle time before scaling to zero.            |
| `aurora_deletion_protection`      | `false`                | `true` blocks `terraform destroy`.           |
| `aurora_vpc_cidr`                 | `10.42.0.0/16`         | Private VPC hosting the cluster.             |
| `lambda_runtime`                  | `nodejs24.x`           | Shared by every service.                     |
| `lambda_reserved_concurrency`     | `-1`                   | `-1` unreserved; a positive value caps it.   |
| `enable_xray_tracing`             | `true`                 | Active tracing + the matching IAM grants.    |
| `throttling_rate_limit`           | `50`                   | Requests/second per API Gateway stage.       |
| `throttling_burst_limit`          | `100`                  | Burst capacity; must be ≥ the rate limit.    |
| `web_cors_allow_origins`          | `[]`                   | Empty omits CORS. `"*"` is rejected.         |
| `api_cors_allow_origins`          | `[]`                   | Empty omits CORS. `"*"` is rejected.         |
| `bff_cors_allow_origins`          | `[]`                   | Empty omits CORS. `"*"` is rejected.         |
| `enable_custom_domain`            | `true`                 | Cloudflare + ACM + custom domains + site.    |
| `web_domain_name`                 | `""`                   | Must differ from `site_domain_name`.         |
| `api_domain_name`                 | `""`                   | e.g. `api.finances.app.br`.                  |
| `bff_domain_name`                 | `""`                   | e.g. `bff.finances.app.br`.                  |
| `site_domain_name`                | `""`                   | Static site apex and bucket name, e.g. `finances.app.br`. |
| `site_www_redirect`               | `true`                 | `www` record + 301 to the apex.              |
| `site_github_repository`          | `finances-app-br/site` | Only repo the deploy role trusts.            |
| `site_github_deploy_branch`       | `master`               | Only branch the deploy role trusts.          |
| `create_github_oidc_provider`     | `false`                | One per account; `false` reuses it.          |
| `cloudflare_zone_id`              | `""`                   | Zone owning the domains above.               |
| `manage_cloudflare_zone_security` | `false`                | **Zone-wide** SSL mode + HTTPS + HSTS.       |
| `cloudflare_ssl_mode`             | `strict`               | `off`/`flexible`/`full`/`strict`.            |
| `hsts_max_age`                    | `31536000`             | `0` disables the header.                     |
| `hsts_preload`                    | `false`                | Slow to undo — see above.                    |
| `enable_dnssec`                   | `false`                | Needs the DS record at your registrar.       |
| `manage_caa_records`              | `false`                | **Zone-wide** CAA `issue`/`issuewild`.       |
| `caa_issuers`                     | ACM + Cloudflare       | Trimming it can break cert renewal.          |
| `caa_report_email`                | `""`                   | Publishes an `iodef` record when set.        |
| `jwt_authorizer`                  | `null`                 | `{ issuer, audiences }` to enable auth.      |

## Running the migration by hand

The schema script is idempotent, so it can be re-run at any time — for example
after editing `app-bff/src/data/auroraSchema.ts`:

```bash
cd ../app-bff
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
destroy outright. The site bucket is versioned and must be emptied before
`destroy` can delete it. The Cloudflare zone settings survive — see above.
