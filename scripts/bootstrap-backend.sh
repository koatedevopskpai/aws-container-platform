#!/usr/bin/env bash
# =============================================================================
# Bootstrap S3 Backend and DynamoDB Lock Table
# =============================================================================
# ARCHITECTURE DECISION: Separate bootstrap script vs Terraform-managed backend
# Terraform cannot manage its own backend state (chicken-and-egg problem).
# This script creates the S3 bucket and DynamoDB table once, after which
# all Terraform runs use the remote backend.
#
# Usage:
#   ./scripts/bootstrap-backend.sh <environment> <region>
#
# Example:
#   ./scripts/bootstrap-backend.sh prod eu-west-2
#
# SECURITY SAFEGUARD: Bucket versioning and encryption enabled
# State files may contain resource IDs, connection strings, and
# configuration data. Versioning enables recovery from accidental
# deletion/corruption. SSE-S3 encryption at rest is minimal compliance;
# for PCI-DSS workloads, switch to SSE-KMS.
# =============================================================================

set -euo pipefail

ENVIRONMENT="${1:-prod}"
REGION="${2:-eu-west-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

BUCKET_NAME="secondwave-terraform-state-${ACCOUNT_ID}"
TABLE_NAME="secondwave-terraform-locks"

echo "================================================"
echo "Bootstrapping Terraform Backend"
echo "Environment: ${ENVIRONMENT}"
echo "Region:      ${REGION}"
echo "Account:     ${ACCOUNT_ID}"
echo "Bucket:      ${BUCKET_NAME}"
echo "DynamoDB:    ${TABLE_NAME}"
echo "================================================"

# ---------------------------------------------------------------------------
# S3 Bucket for Terraform State
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Per-account state bucket
# Each AWS account gets its own state bucket to prevent cross-account
# state corruption. The bucket name includes the account ID to guarantee
# global uniqueness.
# ---------------------------------------------------------------------------

if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "Bucket ${BUCKET_NAME} already exists."
else
  echo "Creating S3 bucket: ${BUCKET_NAME}"

  # Create bucket (us-east-1 for global, otherwise with LocationConstraint)
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

  # SECURITY SAFEGUARD: Block public access
  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  # SECURITY SAFEGUARD: Enable versioning for state recovery
  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  # SECURITY SAFEGUARD: Encrypt at rest
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
      "Rules": [
        {
          "ApplyServerSideEncryptionByDefault": {
            "SSEAlgorithm": "AES256"
          }
        }
      ]
    }'

  # Enable bucket key for reduced KMS costs (if using KMS)
  # aws s3api put-bucket-encryption \
  #   --bucket "${BUCKET_NAME}" \
  #   --server-side-encryption-configuration '{
  #     "Rules": [
  #       {
  #         "ApplyServerSideEncryptionByDefault": {
  #           "SSEAlgorithm": "aws:kms",
  #           "KMSMasterKeyID": "alias/terraform-state-key"
  #         },
  #         "BucketKeyEnabled": true
  #       }
  #     ]
  #   }'

  # Lifecycle policy to transition old state to Glacier
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "${BUCKET_NAME}" \
    --lifecycle-configuration '{
      "Rules": [
        {
          "ID": "TransitionToGlacier",
          "Status": "Enabled",
          "Prefix": "",
          "Transitions": [
            {
              "Days": 90,
              "StorageClass": "GLACIER"
            }
          ],
          "NoncurrentVersionTransitions": [
            {
              "NoncurrentDays": 30,
              "StorageClass": "GLACIER"
            }
          ]
        }
      ]
    }'

  echo "S3 bucket created and configured."
fi

# ---------------------------------------------------------------------------
# DynamoDB Table for State Locking
# ---------------------------------------------------------------------------

if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "DynamoDB table ${TABLE_NAME} already exists."
else
  echo "Creating DynamoDB table: ${TABLE_NAME}"

  # ARCHITECTURE DECISION: On-demand billing for state locking
  # State lock operations are infrequent (< 10/min). On-demand billing
  # costs less than provisioned capacity for this workload pattern.
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  # Wait for table to become active
  aws dynamodb wait table-exists \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}"

  echo "DynamoDB table created with on-demand billing."
fi

# ---------------------------------------------------------------------------
# Output backend configuration
# ---------------------------------------------------------------------------

echo ""
echo "================================================"
echo "Backend Bootstrap Complete!"
echo "================================================"
echo ""
echo "Configure your Terraform backend as:"
echo ""
echo "terraform {"
echo "  backend \"s3\" {"
echo "    bucket         = \"${BUCKET_NAME}\""
echo "    key            = \"${ENVIRONMENT}/container-platform/terraform.tfstate\""
echo "    region         = \"${REGION}\""
echo "    encrypt        = true"
echo "    dynamodb_table = \"${TABLE_NAME}\""
echo "  }"
echo "}"
echo ""
echo "================================================"
