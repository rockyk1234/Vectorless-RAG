# Vectorless Document Tree v3 handover

## Customer-owned values

Before deployment, the customer chooses and records:

- AWS account ID
- AWS Region
- administrator email
- router and answer model IDs
- whether inference may use a geographic or global profile
- optional DNS alias and matching ACM certificate
- document classifications and retention requirements

Map the customer choices to a local `terraform-v3/terraform.tfvars` file. The file is Git-ignored and must not contain secrets.

```hcl
region           = "<aws-region>"
project_name     = "<lowercase-resource-prefix>"
admin_user_email = "<customer-admin-email>"
router_model_id  = "<router-model-or-inference-profile-id>"
answer_model_id  = "<answer-model-or-inference-profile-id>"

# Optional custom CloudFront name. Supply both values or neither.
cloudfront_aliases         = ["<application.example.com>"]
cloudfront_certificate_arn = "<us-east-1-acm-certificate-arn>"
```

The remaining optional controls and defaults, including retention, Lambda memory and timeouts, concurrency, Cognito token validity, and multipart cleanup, are documented in `terraform-v3/variables.tf`. Record every override in the same tfvars file.

## Prerequisites

- Terraform 1.5 or later
- AWS CLI v2
- Node.js 20.19 or later, or Node.js 22.13 or later, with npm
- Python 3.11 or later, or `uv`
- A customer-approved non-production AWS account and deployment role
- Access to the selected Bedrock models in the target Region
- An ACM certificate in `us-east-1` only when using a custom CloudFront name

## Deployment procedure

Set the same Region and model IDs for the preflight and Terraform configuration. Confirm the AWS identity before creating a plan.

```bash
export AWS_PROFILE='<approved-profile>'
export EXPECTED_AWS_ACCOUNT_ID='<account-id>'
export ROUTER_MODEL_ID='<router-model-id>'
export ANSWER_MODEL_ID='<answer-model-id>'

aws sts get-caller-identity --profile "$AWS_PROFILE"
./scripts/preflight_v3.sh '<aws-region>'
./scripts/build_v3_lambdas.sh
python3 -m unittest discover -s lambdas/tests -v

terraform -chdir=terraform-v3 init
terraform -chdir=terraform-v3 plan -out=v3.plan
terraform -chdir=terraform-v3 apply v3.plan
```

Before publishing the frontend, request the Terraform `web_url` output at `/api/ask/orders` without a token. Continue only when it returns HTTP 401 with `Sign in required`. Then run `scripts/deploy_v3_frontend.sh`, which reconfirms the account, installs the locked frontend dependencies with `npm ci`, builds the frontend, uploads without deleting existing objects, and invalidates CloudFront.

## Required gates

1. Confirm the Region supports Lambda, S3, DynamoDB, KMS, Cognito, Textract, Bedrock, and the selected models.
2. Run `scripts/preflight_v3.sh` with the chosen Region and model IDs.
3. Build the frontend and Lambda artifacts locally.
4. Run unit tests, dependency audits, infrastructure validation, security scanning, and an independent code-quality review against the exact commit being handed over.
5. Review the Terraform plan with the customer. Confirm account, Region, IAM policies, encryption key, retention, and Cognito invitation recipient.
6. Apply only after customer approval.
7. Upload only documents approved for the customer environment.
8. Run retrieval regression questions and retain the evidence with the commit and scan reports.

## Data handling

- The repository contains no customer PDF.
- `data/private/` is ignored and must remain untracked.
- Source PDFs, extracted text, trees, figures, and metadata are stored in customer-owned AWS resources.
- CloudWatch audit records contain hashes and routing metadata, not question or quote text.
- Questions use JSON POST bodies so CloudFront access logs do not capture question text in URL query fields.
- CloudFront and S3 access logs contain requester metadata, source IP addresses, user agents, and object paths. WAF logs redact `x-id-token`. Classify, retain, and restrict all access logs under the customer's logging policy.
- Presigned PDF and figure links expire after 15 minutes.

## Operational checks

- Watch the ingest Lambda log for Textract status, section count, figure count, and final tree identifier.
- Confirm the DynamoDB `CURRENT` pointer references the intended revision.
- Confirm the tree and every referenced section key exist before using a document.
- Watch query duration against the 60-second CloudFront and 90-second Lambda timeouts.
- Monitor Bedrock throttling, Lambda errors, S3 request errors, DynamoDB errors, the ingest DLQ, X-Ray traces, and WAF metrics.
- Confirm CloudFront and S3 access logs arrive in the dedicated access-log bucket and expire under the configured lifecycle rule.
- Review model lifecycle and Region support before changing models or copying the stack to another Region.

## Post-deploy verification

1. Confirm the CloudFront homepage returns HTTP 200.
2. Confirm anonymous GET and POST requests to `/api/ask` return HTTP 401.
3. Confirm the direct Lambda Function URL returns HTTP 403.
4. Upload only an approved synthetic manual and confirm Textract completes, tree and section objects exist, and the DynamoDB `CURRENT` pointer is set.
5. Run a known-answer query and require a quote that exactly matches the stored section.
6. Run an absent-answer query and require `NOT_FOUND` with no generated answer.
7. Confirm the ingest DLQ is empty, X-Ray traces have no faults, all S3 public-access blocks are enabled, and encrypted logs are arriving.
8. Run `terraform plan -detailed-exitcode` and require no drift.

## Cleanup and troubleshooting

For guided teardown, run `scripts/teardown_v3.sh` from the same working directory and Terraform state used for deployment. Add `--profile PROFILE` when using a named AWS CLI profile. The script inventories the exact account, Region, resources, object versions, and multipart uploads; backs up local state; obtains separate confirmations for data deletion and Terraform destroy; and verifies each service after completion.

Teardown is destructive. Obtain customer approval, preserve required evidence, disable Cognito deletion protection in an approved plan, empty all versions from the three S3 buckets under the customer's deletion process, and review a dedicated Terraform destroy plan before applying it.

For failures, use the following order:

- Preflight failure: confirm the explicit Region, model IDs, model access, and forced-tool response.
- Anonymous response other than 401: stop before frontend publication and inspect CloudFront OAC, the Function URL policy, and Cognito validation.
- Ingest failure: inspect the ingest log, Textract status, X-Ray trace, and DLQ message before redrive.
- Query dependency error: inspect the stable AWS error code and X-Ray trace for Bedrock, DynamoDB, or S3 failures.
- Bucket teardown failure: stop and check retained object versions and incomplete multipart uploads. Do not bypass the approved retention process.

## Known limitations

- Order and compatibility files are demonstration fixtures.
- Figure content is not interpreted by the answer model.
- AWS WAF applies the common and known-bad-input managed rule groups. Per-user rate limiting, enterprise federation, alarms, dashboards, automated restore tests, and a production support model remain customer production-hardening work.
- Lambda code signing is not enabled because this repository builds unsigned local ZIP files. A production release process must sign the function and layer artifacts and attach an enforcing code-signing configuration.
- Cross-Region S3 replication and CloudFront origin failover are intentionally absent. Customers must select recovery controls that match data residency, recovery point, recovery time, and cost requirements.
- The standard CloudFront domain prioritizes portable deployment. Customers requiring a TLS 1.2 minimum viewer policy should provide a custom domain and an ACM certificate in `us-east-1`.

## Ownership after handover

The customer owns deployment, access, data classification, model selection, monitoring, incident response, cost controls, backups, and production hardening. The proof of concept carries no production warranty, service-level objective, or ongoing support commitment.
