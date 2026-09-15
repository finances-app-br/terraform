# finances — static site infrastructure

Terraform for the static marketing site at `finances.app.br` (landing page and
institutional pages): an **S3 website bucket** behind **Cloudflare**, plus the
**GitHub OIDC role** the `site` repository's workflow uses to deploy.

This is a root module with **its own state**, separate from the platform stack
in [`..`](../README.md) (API Gateway, Lambda, Aurora). Provisioning or
destroying the site never plans, refreshes or builds anything of the platform.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # set cloudflare_zone_id
terraform init
terraform apply
```

Or from the repository root, in one command: `terraform -chdir=site apply`.

`CLOUDFLARE_API_TOKEN` comes from `../.envrc` (direnv loads the nearest
`.envrc` up the tree). Shells that skip the direnv hook — scripts, CI, Claude
Code's Bash tool — need `source ../.envrc` first.

After the first apply, wire the site repository's secrets:

```bash
gh secret set AWS_DEPLOY_ROLE_ARN --repo finances-app-br/site --body "$(terraform output -raw deploy_role_arn)"
gh secret set CF_ZONE_ID          --repo finances-app-br/site --body "<zone id>"
gh secret set CF_API_TOKEN        --repo finances-app-br/site   # token with Zone:Cache Purge only
```

From then on every push to `master` in the site repository builds it, syncs
`dist/` into the bucket and purges only the page URLs from Cloudflare.
Terraform never uploads content.

## What it provisions

```
GitHub Actions ──(OIDC)──► deploy role ──► S3 sync + Cloudflare purge
Browser ──HTTPS──► Cloudflare edge (proxied) ──HTTP──► S3 website endpoint
                   (cache, redirects, headers)          (Cloudflare IPs only)
```

- **S3** bucket named `domain_name`, configured as a website (index and error
  document `index.html`), versioned, encrypted, readable only from Cloudflare's
  IP ranges.
- **Cloudflare**: proxied `CNAME` for the apex (CNAME flattening) and `www`, and
  four zone rulesets — SSL `flexible` for the site hosts, cache TTLs, redirects
  (www → apex, HTTP → HTTPS) and browser security headers.
- **IAM**: deploy role trusted only by `github_repository` on
  `github_deploy_branch`, allowed to list and write that bucket only. The GitHub
  OIDC provider is looked up (`create_github_oidc_provider = false`) because an
  account holds a single one.

Cache: content-hashed assets get 30 days at the edge and in the browser; pages
(`.html` and directory URLs like `/contato/`) get 1 hour at the edge and 5
minutes in the browser.

## Sharing the zone with the platform stack

Both stacks manage the same Cloudflare zone, so ownership is split and must stay
that way:

| Owned by the platform stack (`..`)                     | Owned by this stack                          |
| ------------------------------------------------------ | -------------------------------------------- |
| Zone settings: SSL mode `strict`, Always Use HTTPS, HSTS | Apex and `www` DNS records                   |
| DNSSEC and CAA records                                  | Every ruleset: config, cache, redirect, response headers |
| `api`/`bff` records and their ACM validation records    |                                              |

Consequences:

- **SSL is `flexible` for the site hosts only**, through a Configuration Rule.
  The S3 website endpoint has no HTTPS listener, while the zone stays `strict`
  for API Gateway. Never lower the zone-wide `cloudflare_ssl_mode` to fix a site
  525/526 — it would open a cleartext leg for api/bff.
- **Rulesets are zone entrypoints: one per phase per zone.** A new rule in the
  `http_config_settings`, `http_request_cache_settings`,
  `http_request_dynamic_redirect` or `http_response_headers_transform` phase —
  for any hostname, api/bff included — goes into the resources here. If apply
  fails with "a similar configuration with rules already exists", a ruleset for
  that phase was created elsewhere: import it.
- **Every rule is scoped to the site hostnames**, so cache TTLs never apply to
  API responses.
- **The apex belongs to this stack.** Keep `web_domain_name` in the platform
  stack off `finances.app.br`; Cloudflare refuses a second CNAME at the same
  name, so the second apply fails.
- **The platform's CAA records must keep Cloudflare's CAs** (the `caa_issuers`
  default does): the site's HTTPS runs on Cloudflare's edge certificate.
- **The site works without the platform applied**: it has its own HTTP → HTTPS
  redirect instead of relying on the zone's Always Use HTTPS.

## Troubleshooting

**`81053: An A, AAAA, or CNAME record with that host already exists`** on
`cloudflare_dns_record.apex` (or `www`): the zone already has a record at that
name — typically created in the dashboard when the zone was added, or by the
platform stack if `web_domain_name` points at the apex. Bring it under this
stack instead of creating a duplicate:

```bash
source ../.envrc
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone id>/dns_records?name=finances.app.br" \
  | jq -c '.result[] | {id, type, content, proxied, comment}'

terraform import cloudflare_dns_record.apex <zone id>/<record id>
terraform plan -out plan.out   # expect the record to become the proxied CNAME to S3
terraform apply plan.out
```

A failed apply keeps in state everything it did create, so re-plan after the
import — the earlier `plan.out` is stale.

**`security` exits 36 / `CLOUDFLARE_API_TOKEN` is empty**: the keychain cannot
show its access prompt from that process (non-interactive or sandboxed shells).
Run the command from a regular terminal.

## Cloudflare token

`CLOUDFLARE_API_TOKEN` needs, on the zone: **DNS: Edit**, **Config Rules: Edit**,
**Cache Rules: Edit**, **Single Redirect: Edit** and **Transform Rules: Edit**.
Each ruleset phase is a separate permission group. No Zone Settings permission
is needed here.

## Variables

| Variable                      | Default                | Notes                                        |
| ----------------------------- | ---------------------- | -------------------------------------------- |
| `cloudflare_zone_id`          | —                      | Required; same zone as the platform stack.   |
| `domain_name`                 | `finances.app.br`      | Apex and S3 bucket name.                     |
| `www_redirect`                | `true`                 | `www` record + 301 to the apex.              |
| `github_repository`           | `finances-app-br/site` | Only repo the deploy role trusts.            |
| `github_deploy_branch`        | `master`               | Only branch the deploy role trusts.          |
| `create_github_oidc_provider` | `false`                | One per account; `false` reuses it.          |
| `project_name`                | `finances-site`        | IAM name prefix and `Project` tag.           |
| `aws_region`                  | `us-east-1`            |                                              |
| `tags`                        | `{}`                   | Extra tags on every AWS resource.            |

## Destroy

```bash
terraform destroy
```

The bucket is versioned: empty it (every object version) before `destroy` can
delete it. Removing the rulesets leaves the zone without cache/redirect/header
rules; the platform stack is unaffected.
