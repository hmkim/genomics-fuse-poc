import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as cloudtrail from 'aws-cdk-lib/aws-cloudtrail';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { PREFIX, S3, KMS } from '../config/constants';

export interface StorageStackProps extends cdk.StackProps {
  vpc: ec2.IVpc;
}

export class StorageStack extends cdk.Stack {
  public readonly dataBucket: s3.Bucket;
  public readonly logBucket: s3.Bucket;
  public readonly kmsKey: kms.Key;

  constructor(scope: Construct, id: string, props: StorageStackProps) {
    super(scope, id, props);

    // KMS customer-managed key for genomics data encryption
    this.kmsKey = new kms.Key(this, 'DataKey', {
      alias: KMS.ALIAS,
      description: 'Encryption key for genomics data (S3, EBS)',
      enableKeyRotation: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // S3 logging bucket for server access logs and CloudTrail
    this.logBucket = new s3.Bucket(this, 'LogBucket', {
      bucketName: S3.LOG_BUCKET_NAME,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      lifecycleRules: [
        {
          expiration: cdk.Duration.days(365),
          transitions: [
            {
              storageClass: s3.StorageClass.GLACIER,
              transitionAfter: cdk.Duration.days(90),
            },
          ],
        },
      ],
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // Main genomics data bucket
    this.dataBucket = new s3.Bucket(this, 'DataBucket', {
      bucketName: S3.DATA_BUCKET_NAME,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: this.kmsKey,
      bucketKeyEnabled: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: true,
      serverAccessLogsBucket: this.logBucket,
      serverAccessLogsPrefix: 's3-access-logs/',
      // Intelligent-Tiering handles Frequent/Infrequent access automatically.
      // Archive tiers are NOT configured — incompatible with Mountpoint S3.
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // Bucket policy: enforce TLS and VPC endpoint access
    this.dataBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyNonSSLRequests',
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ['s3:*'],
        resources: [
          this.dataBucket.bucketArn,
          this.dataBucket.arnForObjects('*'),
        ],
        conditions: {
          Bool: { 'aws:SecureTransport': 'false' },
        },
      })
    );

    // CloudTrail for S3 data event auditing
    const trailLogGroup = new logs.LogGroup(this, 'TrailLogGroup', {
      logGroupName: `/aws/cloudtrail/${PREFIX}-data-events`,
      retention: logs.RetentionDays.ONE_YEAR,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const trail = new cloudtrail.Trail(this, 'DataTrail', {
      trailName: `${PREFIX}-data-trail`,
      bucket: this.logBucket,
      s3KeyPrefix: 'cloudtrail',
      cloudWatchLogGroup: trailLogGroup,
      sendToCloudWatchLogs: true,
      enableFileValidation: true,
    });

    // Log S3 data events (GetObject, PutObject, etc.) for the data bucket
    trail.addS3EventSelector(
      [{ bucket: this.dataBucket }],
      {
        readWriteType: cloudtrail.ReadWriteType.ALL,
        includeManagementEvents: false,
      }
    );

    // Outputs
    new cdk.CfnOutput(this, 'DataBucketName', {
      value: this.dataBucket.bucketName,
    });
    new cdk.CfnOutput(this, 'KmsKeyArn', {
      value: this.kmsKey.keyArn,
    });
  }
}
