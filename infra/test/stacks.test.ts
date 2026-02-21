import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { NetworkStack } from '../lib/stacks/network-stack';
import { StorageStack } from '../lib/stacks/storage-stack';
import { DatabaseStack } from '../lib/stacks/database-stack';
import { AuthStack } from '../lib/stacks/auth-stack';
import { ComputeStack } from '../lib/stacks/compute-stack';

const env = { account: process.env.CDK_DEFAULT_ACCOUNT || '<YOUR_ACCOUNT_ID>', region: 'ap-northeast-2' };

describe('NetworkStack', () => {
  const app = new cdk.App();
  const stack = new NetworkStack(app, 'TestNetwork', { env });
  const template = Template.fromStack(stack);

  test('creates VPC', () => {
    template.resourceCountIs('AWS::EC2::VPC', 1);
    template.hasResourceProperties('AWS::EC2::VPC', {
      CidrBlock: '10.0.0.0/16',
      EnableDnsHostnames: true,
      EnableDnsSupport: true,
    });
  });

  test('creates S3 gateway endpoint', () => {
    template.hasResourceProperties('AWS::EC2::VPCEndpoint', {
      ServiceName: Match.objectLike({
        'Fn::Join': Match.anyValue(),
      }),
      VpcEndpointType: 'Gateway',
    });
  });

  test('creates security group', () => {
    template.resourceCountIs('AWS::EC2::SecurityGroup', 1);
  });

  test('creates NAT gateway', () => {
    template.resourceCountIs('AWS::EC2::NatGateway', 1);
  });
});

describe('StorageStack', () => {
  const app = new cdk.App();
  const network = new NetworkStack(app, 'TestNetwork2', { env });
  const stack = new StorageStack(app, 'TestStorage', { env, vpc: network.vpc });
  const template = Template.fromStack(stack);

  test('creates KMS key with rotation', () => {
    template.hasResourceProperties('AWS::KMS::Key', {
      EnableKeyRotation: true,
    });
  });

  test('creates data bucket with KMS encryption', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: Match.stringLikeRegexp('genomics-data-.*'),
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          {
            BucketKeyEnabled: true,
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'aws:kms',
            },
          },
        ],
      },
      VersioningConfiguration: {
        Status: 'Enabled',
      },
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
    });
  });

  test('creates log bucket', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: Match.stringLikeRegexp('genomics-logs-.*'),
    });
  });

  test('creates CloudTrail', () => {
    template.hasResourceProperties('AWS::CloudTrail::Trail', {
      TrailName: 'genomics-data-trail',
      IsLogging: true,
      EnableLogFileValidation: true,
    });
  });
});

describe('DatabaseStack', () => {
  const app = new cdk.App();
  const stack = new DatabaseStack(app, 'TestDatabase', { env });
  const template = Template.fromStack(stack);

  test('creates DynamoDB table with correct schema', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'genomics-eid-mapping',
      KeySchema: [
        { AttributeName: 'project_id', KeyType: 'HASH' },
        { AttributeName: 'eid', KeyType: 'RANGE' },
      ],
      BillingMode: 'PAY_PER_REQUEST',
      PointInTimeRecoverySpecification: {
        PointInTimeRecoveryEnabled: true,
      },
    });
  });

  test('creates GSI for internal_id lookup', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      GlobalSecondaryIndexes: [
        {
          IndexName: 'internal_id-index',
          KeySchema: [{ AttributeName: 'internal_id', KeyType: 'HASH' }],
          Projection: { ProjectionType: 'ALL' },
        },
      ],
    });
  });
});

describe('AuthStack', () => {
  const app = new cdk.App();
  const network = new NetworkStack(app, 'TestNetwork3', { env });
  const storage = new StorageStack(app, 'TestStorage3', {
    env,
    vpc: network.vpc,
  });
  const database = new DatabaseStack(app, 'TestDatabase3', { env });
  const stack = new AuthStack(app, 'TestAuth', {
    env,
    dataBucket: storage.dataBucket,
    eidTable: database.eidTable,
  });
  const template = Template.fromStack(stack);

  test('creates Cognito User Pool', () => {
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      UserPoolName: 'genomics-researchers',
      Policies: {
        PasswordPolicy: {
          MinimumLength: 12,
          RequireLowercase: true,
          RequireUppercase: true,
          RequireNumbers: true,
          RequireSymbols: true,
        },
      },
    });
  });

  test('creates Identity Pool', () => {
    template.hasResourceProperties('AWS::Cognito::IdentityPool', {
      AllowUnauthenticatedIdentities: false,
    });
  });

  test('creates project groups', () => {
    template.resourceCountIs('AWS::Cognito::UserPoolGroup', 3);
  });

  test('creates project IAM roles', () => {
    // 3 project roles + 1 authenticated role = 4
    template.resourceCountIs('AWS::IAM::Role', 4);
  });
});

describe('ComputeStack', () => {
  const app = new cdk.App();
  const network = new NetworkStack(app, 'TestNetwork4', { env });
  const storage = new StorageStack(app, 'TestStorage4', {
    env,
    vpc: network.vpc,
  });
  const database = new DatabaseStack(app, 'TestDatabase4', { env });
  const auth = new AuthStack(app, 'TestAuth4', {
    env,
    dataBucket: storage.dataBucket,
    eidTable: database.eidTable,
  });
  const stack = new ComputeStack(app, 'TestCompute', {
    env,
    vpc: network.vpc,
    workstationSg: network.workstationSg,
    dataBucket: storage.dataBucket,
    kmsKey: storage.kmsKey,
    eidTable: database.eidTable,
    userPool: auth.userPool,
  });
  const template = Template.fromStack(stack);

  test('creates 3 Lambda functions', () => {
    template.resourceCountIs('AWS::Lambda::Function', 3);
  });

  test('creates eid-resolver Lambda', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'genomics-eid-resolver',
      Runtime: 'nodejs20.x',
      MemorySize: 256,
      Timeout: 10,
    });
  });

  test('creates session-init Lambda', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'genomics-session-init',
      Runtime: 'nodejs20.x',
      MemorySize: 512,
      Timeout: 30,
    });
  });

  test('creates data-seeder Lambda', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'genomics-data-seeder',
      Runtime: 'nodejs20.x',
      MemorySize: 256,
      Timeout: 60,
    });
  });

  test('creates EC2 instance', () => {
    template.hasResourceProperties('AWS::EC2::Instance', {
      InstanceType: 't3.large',
    });
  });
});
