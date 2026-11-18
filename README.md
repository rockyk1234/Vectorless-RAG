# Vectorless Document Tree v3

Vectorless Document Tree v3 retrieves grounded answers from known technical manuals without a vector database. It maps an order to a manual, routes each question through the manual hierarchy, fetches only the selected sections, and returns an answer only when every citation matches stored source text.

## How it works

1. An order maps to a known part and manual.
2. Amazon Textract extracts document layout and tables during ingestion.
3. Amazon Bedrock summarizes the manual into a document tree stored in Amazon S3.
4. A Bedrock router selects relevant tree nodes for each question.
5. The application fetches only those source sections.
6. A Bedrock answer model returns an answer and verbatim quotes.
7. Python verifies every quote against the stored source. Failed verification returns `NOT_FOUND`.

Responses include the manual revision, source pages, verified quotes, and short-lived links to the source PDF and relevant figures.

## Architecture

```text
Browser -> Amazon Cognito -> AWS WAF -> Amazon CloudFront

CloudFront -> private Amazon S3 web bucket
CloudFront -> IAM-protected Lambda Function URL

Query Lambda -> Amazon DynamoDB metadata
Query Lambda -> selected Amazon S3 sections
Query Lambda -> Amazon Bedrock

PDF upload -> encrypted Amazon S3 bucket -> Ingest Lambda
Ingest Lambda -> Amazon Textract
Ingest Lambda -> Amazon Bedrock summaries
Ingest Lambda -> document tree, sections, figures, and revision metadata
```

The stack also configures AWS KMS encryption, Amazon SQS dead-letter handling, AWS X-Ray tracing, CloudWatch logging, S3 and CloudFront access logging, S3 versioning, and DynamoDB point-in-time recovery.

## Prerequisites

Use a customer-approved non-production AWS account with permissions to create the resources above.

Install:

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Terraform](https://developer.hashicorp.com/terraform/install), version 1.5 or later
- Node.js 20.19 or later, or Node.js 22.13 or later, with npm
- Python 3.11 or later, or `uv`
- Git

The selected account must have access to the configured [Amazon Bedrock models](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html).

## Quick start

Clone the repository and enter its root directory:

```bash
git clone https://github.com/rockyk1234/Vectorless-RAG.git
cd Vectorless-RAG
```

The deployment script uses active AWS credentials from the standard AWS credential chain. Confirm the intended account before starting:

```bash
aws sts get-caller-identity
```

Run a build, compatibility check, and Terraform plan without creating resources:

```bash
./scripts/setup_and_deploy_v3.sh --plan-only
```

Run the complete guided deployment:

```bash
./scripts/setup_and_deploy_v3.sh
```

If you use a named AWS CLI profile:

```bash
./scripts/setup_and_deploy_v3.sh --profile customer-deployment
```


The guided script:

- asks for the AWS Region, administrator email, and project name
- verifies the exact AWS account and role
- uses Claude Haiku 4.5 for routing and Claude Sonnet 4.6 for answers
- runs tests, builds, dependency checks, and regional model preflight
- creates and validates a Terraform plan
- rejects plans containing updates or deletions for a fresh deployment
- asks for confirmation before creating resources
- requires an anonymous HTTP 401 response before publishing the frontend
- optionally downloads the tested Danfoss manual from its official source, verifies it, uploads it, and waits for ingestion
- prints the final application URL

The administrator email receives the temporary password for first sign-in. Deployment-specific values are written to the Git-ignored `terraform-v3/terraform.tfvars` file. Credentials are never written to the repository or Terraform configuration.

The Region menu includes:

- US East, N. Virginia: `us-east-1`
- US East, Ohio: `us-east-2`
- US West, Oregon: `us-west-2`
- Europe, Ireland: `eu-west-1`
- Europe, London: `eu-west-2`
- Europe, Frankfurt: `eu-central-1`
- Asia Pacific, Singapore: `ap-southeast-1`
- Asia Pacific, Sydney: `ap-southeast-2`

The preflight makes bounded, billable Bedrock requests to verify model access and forced tool use before Terraform can apply. The default global Bedrock inference profiles may process requests outside the selected source Region. Customers with strict data residency requirements should select suitable direct or geographic inference profiles using the [manual deployment procedure](docs/HANDOVER.md).

## Test with the Danfoss manual

The demo uses the [Danfoss VLT Midi Drive FC 280 operating instructions](https://files.danfoss.com/download/Drives/MG07A102.pdf) with `ORD-1001`. The PDF is downloaded from Danfoss and is not stored in this repository.

If the download was skipped during guided deployment, fetch, verify, and upload it with:

```bash
./scripts/fetch_and_upload_danfoss.sh
```

The command requires the official download to match the tested SHA-256 checksum before uploading it to the Terraform-managed encrypted S3 bucket.

After ingestion completes, sign in and try:

- `ORD-1001`: What torque do I use for the mains terminals?

Ask an unrelated question to confirm the application returns `NOT_FOUND` instead of generating an unsupported answer.

Do not commit customer documents. Store local private test files under `data/private/`, which Git ignores, and upload only approved documents to the customer-owned AWS account.

## Security summary

- Amazon Cognito Managed Login uses authorization code flow with PKCE.
- CloudFront privately accesses the S3 origin and IAM-protected Lambda Function URL.
- AWS WAF applies managed common and known-bad-input protections.
- S3 public access blocks remain enabled.
- Documents and application logs use customer managed AWS KMS keys.
- Questions use POST bodies and are not written to CloudFront URL logs.
- Application audit records contain hashes and routing metadata rather than question or quote text.
- PDF and figure links are signed and expire after 15 minutes.

Review [docs/HANDOVER.md](docs/HANDOVER.md) before using the proof of concept with customer data or extending it toward production.

## Pilot cost estimate

The pilot estimate assumes:

- 10 manuals at 20 pages each
- 600 queries per month
- 10 active users
- 2 GB of stored data
- 0.1 GB of CloudFront data transfer

Estimated monthly cost: **$26**.

The estimate includes Amazon Bedrock, Amazon Textract, Lambda, AWS WAF, AWS KMS, S3, DynamoDB, CloudFront, Cognito, CloudWatch, AWS X-Ray, and Amazon SQS. Bedrock and Textract usage varies with document structure, token volume, query depth, and reprocessing frequency.

Pricing references: [Amazon Bedrock](https://aws.amazon.com/bedrock/pricing/), [Amazon Textract](https://aws.amazon.com/textract/pricing/), [AWS Lambda](https://aws.amazon.com/lambda/pricing/), [AWS WAF](https://aws.amazon.com/waf/pricing/), and [AWS KMS](https://aws.amazon.com/kms/pricing/).

## Detailed documentation

- [Customer handover, manual deployment, verification, and cleanup](docs/HANDOVER.md)
- [Architecture decision record](docs/adr/001-v3-storage-and-api.md)
- [Terraform variables](terraform-v3/variables.tf)
- [Sample-document mappings and checksums](sample-documents/README.md)

## Cleanup

Run teardown from the same directory and Terraform state used for deployment:

```bash
./scripts/teardown_v3.sh
```

Use `--profile PROFILE` when the deployment used a named AWS CLI profile. The script inventories and backs up the state, requires confirmation before permanent data deletion, removes the Terraform-managed stack, and verifies every service afterward. AWS KMS keys enter a 30-day pending-deletion period.

Teardown permanently removes documents, processed sections, logs, and user access. Preserve required data and obtain approval first. See [docs/HANDOVER.md](docs/HANDOVER.md) for the manual procedure.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
