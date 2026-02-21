export const ENV = {
  ACCOUNT: process.env.CDK_DEFAULT_ACCOUNT || '<YOUR_ACCOUNT_ID>',
  REGION: 'ap-northeast-2',
};

export const PREFIX = 'genomics';

export const VPC = {
  CIDR: '10.0.0.0/16',
  MAX_AZS: 2,
  NAT_GATEWAYS: 1,
};

export const S3 = {
  DATA_BUCKET_NAME: `${PREFIX}-data-${ENV.ACCOUNT}`,
  LOG_BUCKET_NAME: `${PREFIX}-logs-${ENV.ACCOUNT}`,
  PREFIXES: {
    CRAM: 'internal/cram/',
    REFERENCE: 'reference/GRCh38/',
    METADATA: 'metadata/eid_mapping/',
  },
};

export const DYNAMO = {
  TABLE_NAME: `${PREFIX}-eid-mapping`,
  GSI_NAME: 'internal_id-index',
};

export const COGNITO = {
  USER_POOL_NAME: `${PREFIX}-researchers`,
  DOMAIN_PREFIX: `${PREFIX}-auth-${ENV.ACCOUNT}`,
};

export const PROJECTS = ['project_001', 'project_002', 'project_1kg'];

export const KMS = {
  ALIAS: `alias/${PREFIX}-data-key`,
};

export const EC2_CONFIG = {
  INSTANCE_TYPE: 't3.large',
  VOLUME_SIZE_GB: 100,
};

export const TAGS = {
  Project: 'GenomicsResearchPlatform',
  Environment: 'production',
  ManagedBy: 'CDK',
};
