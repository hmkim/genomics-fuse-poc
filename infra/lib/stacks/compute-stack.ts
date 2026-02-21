import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import { Construct } from 'constructs';
import * as path from 'path';
import { PREFIX, EC2_CONFIG, S3 } from '../config/constants';

export interface ComputeStackProps extends cdk.StackProps {
  vpc: ec2.IVpc;
  workstationSg: ec2.ISecurityGroup;
  dataBucket: s3.IBucket;
  kmsKey: kms.IKey;
  eidTable: dynamodb.ITable;
  userPool: cognito.IUserPool;
}

export class ComputeStack extends cdk.Stack {
  public readonly eidResolverFn: nodejs.NodejsFunction;
  public readonly sessionInitFn: nodejs.NodejsFunction;
  public readonly dataSeederFn: nodejs.NodejsFunction;

  constructor(scope: Construct, id: string, props: ComputeStackProps) {
    super(scope, id, props);

    // --- Lambda 1: eid-resolver ---
    this.eidResolverFn = new nodejs.NodejsFunction(this, 'EidResolver', {
      functionName: `${PREFIX}-eid-resolver`,
      entry: path.join(__dirname, '../../lambda/eid-resolver/index.ts'),
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_20_X,
      memorySize: 256,
      timeout: cdk.Duration.seconds(10),
      environment: {
        TABLE_NAME: props.eidTable.tableName,
        BUCKET_NAME: props.dataBucket.bucketName,
      },
      bundling: {
        minify: true,
        sourceMap: true,
      },
    });
    props.eidTable.grantReadData(this.eidResolverFn);

    // --- Lambda 2: session-init ---
    this.sessionInitFn = new nodejs.NodejsFunction(this, 'SessionInit', {
      functionName: `${PREFIX}-session-init`,
      entry: path.join(__dirname, '../../lambda/session-init/index.ts'),
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_20_X,
      memorySize: 512,
      timeout: cdk.Duration.seconds(30),
      environment: {
        TABLE_NAME: props.eidTable.tableName,
        BUCKET_NAME: props.dataBucket.bucketName,
      },
      bundling: {
        minify: true,
        sourceMap: true,
      },
    });
    props.eidTable.grantReadData(this.sessionInitFn);

    // --- Lambda 3: data-seeder ---
    this.dataSeederFn = new nodejs.NodejsFunction(this, 'DataSeeder', {
      functionName: `${PREFIX}-data-seeder`,
      entry: path.join(__dirname, '../../lambda/data-seeder/index.ts'),
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_20_X,
      memorySize: 256,
      timeout: cdk.Duration.seconds(60),
      environment: {
        TABLE_NAME: props.eidTable.tableName,
        BUCKET_NAME: props.dataBucket.bucketName,
      },
      bundling: {
        minify: true,
        sourceMap: true,
      },
    });
    props.eidTable.grantWriteData(this.dataSeederFn);
    props.dataBucket.grantRead(this.dataSeederFn);
    props.kmsKey.grantDecrypt(this.dataSeederFn);

    // --- EC2 Workstation ---
    const workstationRole = new iam.Role(this, 'WorkstationRole', {
      roleName: `${PREFIX}-workstation-role`,
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    // S3 read access for Mountpoint S3
    props.dataBucket.grantRead(workstationRole);
    props.kmsKey.grantDecrypt(workstationRole);

    // DynamoDB read access for EID lookups
    props.eidTable.grantReadData(workstationRole);

    // Lambda invoke for session-init and eid-resolver
    this.sessionInitFn.grantInvoke(workstationRole);
    this.eidResolverFn.grantInvoke(workstationRole);

    // Amazon Linux 2023 AMI
    const al2023 = ec2.MachineImage.latestAmazonLinux2023();

    const instance = new ec2.Instance(this, 'Workstation', {
      instanceName: `${PREFIX}-workstation`,
      vpc: props.vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      instanceType: new ec2.InstanceType(EC2_CONFIG.INSTANCE_TYPE),
      machineImage: al2023,
      securityGroup: props.workstationSg,
      role: workstationRole,
      blockDevices: [
        {
          deviceName: '/dev/xvda',
          volume: ec2.BlockDeviceVolume.ebs(EC2_CONFIG.VOLUME_SIZE_GB, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
            kmsKey: props.kmsKey,
          }),
        },
      ],
      ssmSessionPermissions: true,
    });

    // User Data: install samtools, mount-s3, and helper scripts
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -euxo pipefail',
      '',
      '# Install samtools build dependencies and compile from source',
      'dnf install -y gcc make bzip2-devel xz-devel zlib-devel libcurl-devel openssl-devel ncurses-devel',
      'cd /tmp',
      'curl -sL https://github.com/samtools/samtools/releases/download/1.21/samtools-1.21.tar.bz2 | tar xjf -',
      'cd samtools-1.21 && ./configure --prefix=/usr/local && make -j$(nproc) && make install',
      '',
      '# Install Mountpoint for Amazon S3',
      'dnf install -y https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm',
      '',
      '# Create mount directories',
      'mkdir -p /mnt/s3-genomics /mnt/project',
    );

    // Write mount-genomics.sh
    userData.addCommands(
      `cat > /usr/local/bin/mount-genomics.sh << 'MOUNTEOF'`,
      '#!/bin/bash',
      'set -e',
      `BUCKET="${props.dataBucket.bucketName}"`,
      'MOUNT_POINT="/mnt/s3-genomics"',
      'if mountpoint -q "$MOUNT_POINT"; then echo "Already mounted at $MOUNT_POINT"; exit 0; fi',
      'mkdir -p "$MOUNT_POINT"',
      'mount-s3 "$BUCKET" "$MOUNT_POINT" --read-only --region ap-northeast-2',
      'echo "Mounted $BUCKET at $MOUNT_POINT"',
      'MOUNTEOF',
      'chmod +x /usr/local/bin/mount-genomics.sh',
    );

    // Write create-symlinks.py helper
    userData.addCommands(
      `cat > /usr/local/bin/create-symlinks.py << 'PYEOF'`,
      'import json, sys, os',
      'with open(sys.argv[1]) as f:',
      '    data = json.load(f)',
      'project_dir = "/mnt/project/" + data.get("mount_config", {}).get("project_id", "unknown")',
      'os.makedirs(project_dir, exist_ok=True)',
      'for m in data.get("mappings", []):',
      '    src = "/mnt/s3-genomics/" + m["symlink_target"]',
      '    dst = project_dir + "/" + m["symlink_source"]',
      '    if not os.path.exists(dst):',
      '        os.symlink(src, dst)',
      '        print("Created: " + dst + " -> " + src)',
      'PYEOF',
      'chmod +x /usr/local/bin/create-symlinks.py',
    );

    // Write setup-project.sh
    const fnName = this.sessionInitFn.functionName;
    userData.addCommands(
      `cat > /usr/local/bin/setup-project.sh << 'SETUPEOF'`,
      '#!/bin/bash',
      'set -e',
      'if [ $# -lt 1 ]; then echo "Usage: setup-project.sh <project_id>"; exit 1; fi',
      'PROJECT_ID="$1"',
      '/usr/local/bin/mount-genomics.sh',
      'TMPFILE=$(mktemp)',
      `aws lambda invoke --function-name ${fnName} \\`,
      '  --payload "{\\"project_id\\":\\"$PROJECT_ID\\",\\"user_id\\":\\"workstation\\"}" \\',
      '  --region ap-northeast-2 --cli-binary-format raw-in-base64-out "$TMPFILE" > /dev/null 2>&1',
      'python3 /usr/local/bin/create-symlinks.py "$TMPFILE"',
      'rm -f "$TMPFILE"',
      'echo "Project $PROJECT_ID ready at /mnt/project/$PROJECT_ID"',
      'SETUPEOF',
      'chmod +x /usr/local/bin/setup-project.sh',
      '',
      '# Auto-mount on boot',
      '/usr/local/bin/mount-genomics.sh || true',
    );

    instance.addUserData(userData.render());

    // Outputs
    new cdk.CfnOutput(this, 'WorkstationInstanceId', {
      value: instance.instanceId,
    });
    new cdk.CfnOutput(this, 'EidResolverArn', {
      value: this.eidResolverFn.functionArn,
    });
    new cdk.CfnOutput(this, 'SessionInitArn', {
      value: this.sessionInitFn.functionArn,
    });
    new cdk.CfnOutput(this, 'DataSeederArn', {
      value: this.dataSeederFn.functionArn,
    });
  }
}
