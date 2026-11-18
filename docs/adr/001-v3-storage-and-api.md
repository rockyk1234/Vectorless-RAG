# ADR 001: Regional, usage-based v3 architecture

## Status

Accepted.

## Context

The solution must preserve deterministic manual partitioning, hierarchical routing, exact section fetches, quote verification, figures, authentication, and the audit trail while remaining portable across AWS Regions supported by the required services. Fixed database clusters, VPC networking, and interface endpoints would create recurring costs even when the demonstration is idle.

Queries can take more than 30 seconds because the request can include several sequential model calls. Customer documents can exceed DynamoDB's item size limit. A customer handover must not contain a confidential source PDF or an endpoint tied to the publisher's demonstration account.

## Decision

### Storage

Use one versioned S3 bucket for source PDFs, tree JSON, section JSON, and figure crops. Use a DynamoDB on-demand table only for current-revision pointers, small revision metadata, and non-secret application configuration.

S3 objects use a customer managed KMS key. The bucket denies non-TLS requests, uploads without SSE-KMS, and uploads that name a different key. Application and upload operations send the expected bucket owner where supported.

### Compute and networking

Run the ingest and query Lambdas outside a customer-managed VPC. They call regional AWS service endpoints. Do not create a NAT gateway, interface endpoint, DocumentDB cluster, OpenSearch collection, or Secrets Manager secret.

### API and authentication

Serve the private SPA from S3 through CloudFront OAC. Send `/api/*` to an `AWS_IAM` Lambda Function URL through a Lambda OAC. Grant CloudFront both Function URL invocation permissions, restricted to the distribution ARN.

Use the Cognito Essentials feature plan and Managed Login version 2 with a managed branding resource for the SPA client. Use the authorization code flow with PKCE because the browser is a public client that cannot protect a client secret. Administrator-created users keep the proof of concept restricted to explicitly invited customer users. CloudFront uses the `Authorization` header for SigV4, so the SPA sends its Cognito ID token in `x-id-token`. The Lambda validates signature, issuer, audience, token type, and expiration. Questions use a JSON POST body rather than URL query parameters so CloudFront and S3 access logs do not capture question text. Browser clients send the SHA-256 body hash required by Lambda Function URL OAC signing. CloudFront consumes that reserved header during signing; the custom origin request policy forwards only the ID token and content type. The API cache behavior forwards the request body but does not cache responses.

Attach an AWS WAF web ACL with the AWS managed common and known-bad-input rule groups. Send CloudFront and S3 access records to a separate encrypted log bucket with lifecycle retention. These controls add fixed and usage-based cost but provide a minimum abuse-protection and request-audit baseline for a customer-shareable application.

Use a 60-second CloudFront origin response timeout. This avoids the 30-second HTTP API integration limit while remaining below the query Lambda's 90-second timeout.

### Region and model selection

Parameterize the source Region. Default to the active global Claude Haiku 4.5 profile for routing and summaries and the active global Claude Sonnet 4.6 profile for answers. Both passed the forced-tool preflight and the 15-question live regression in `us-west-2`. Run the bounded preflight invocation for each selected model before every deployment.

A global or geographic inference profile can process outside the source Region. Customers that require strict single-Region inference must select current direct Bedrock Runtime models available in their Region and rerun the preflight.

### Audit privacy

Log identifiers, routing decisions, lengths, and SHA-256 hashes. Do not log question text, answer text, quote text, tokens, or presigned URLs. Questions are sent in POST bodies because CloudFront standard access logs record URL query strings. Hashes support request correlation and regression evidence without reproducing customer questions or quoted manual content.

## Consequences

- Idle infrastructure cost is lower than a fixed cluster design, although the KMS key and configured retention features can still create recurring charges.
- S3 payloads avoid DynamoDB's item size limit and keep revisions addressable.
- DynamoDB on-demand removes provisioned throughput planning for demonstration traffic.
- CloudFront remains global, but application data stores remain in the selected Region.
- Region portability depends on service and model availability. The preflight turns this into an early deployment gate rather than a runtime surprise.
- The Function URL path has fewer managed API features than API Gateway. Cognito verification, input validation, and audit logging remain application responsibilities.
- Figure interpretation is outside this decision. Figures remain display-only evidence.

## Alternatives considered

### Keep DocumentDB and the VPC

Rejected because the cluster and network endpoints create fixed costs and operational work that the small metadata workload does not require.

### Store full sections in DynamoDB

Rejected because technical-manual sections, tables, and trees can approach or exceed DynamoDB's 400 KB item limit. Splitting large text solely to satisfy the database would complicate exact retrieval.

### Use API Gateway HTTP API with a JWT authorizer

Rejected for this proof of concept because HTTP API integrations have a 30-second maximum timeout, while measured document-tree queries can take 20 to 40 seconds. CloudFront plus Lambda Function URL supports the required 60-second origin wait.

### Use OpenSearch or a vector database

Rejected because the selected manual and its hierarchy are known before retrieval. Exact partitioning and exact object keys provide the required behavior without an always-on search tier.

### Bundle static Cognito signing keys

Rejected because Cognito rotates keys. The Lambda loads the issuer JWKS, caches it, and refreshes once when a token uses an unknown key identifier.
