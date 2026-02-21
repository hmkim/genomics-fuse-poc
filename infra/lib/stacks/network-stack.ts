import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';
import { PREFIX, VPC } from '../config/constants';

export class NetworkStack extends cdk.Stack {
  public readonly vpc: ec2.Vpc;
  public readonly workstationSg: ec2.SecurityGroup;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // VPC with public and private subnets across 2 AZs
    this.vpc = new ec2.Vpc(this, 'Vpc', {
      vpcName: `${PREFIX}-vpc`,
      ipAddresses: ec2.IpAddresses.cidr(VPC.CIDR),
      maxAzs: VPC.MAX_AZS,
      natGateways: VPC.NAT_GATEWAYS,
      subnetConfiguration: [
        {
          cidrMask: 24,
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
        },
        {
          cidrMask: 24,
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
        },
      ],
      enableDnsHostnames: true,
      enableDnsSupport: true,
    });

    // S3 Gateway Endpoint — critical for Mountpoint S3 performance (no data transfer cost)
    this.vpc.addGatewayEndpoint('S3Endpoint', {
      service: ec2.GatewayVpcEndpointAwsService.S3,
    });

    // DynamoDB Gateway Endpoint — for Lambda EID lookups
    this.vpc.addGatewayEndpoint('DynamoDbEndpoint', {
      service: ec2.GatewayVpcEndpointAwsService.DYNAMODB,
    });

    // Security group for EC2 workstations
    this.workstationSg = new ec2.SecurityGroup(this, 'WorkstationSg', {
      vpc: this.vpc,
      securityGroupName: `${PREFIX}-workstation-sg`,
      description: 'Security group for genomics research workstations',
      allowAllOutbound: true,
    });

    // Allow SSH only from within the VPC
    this.workstationSg.addIngressRule(
      ec2.Peer.ipv4(VPC.CIDR),
      ec2.Port.tcp(22),
      'SSH from VPC internal'
    );

    // Outputs
    new cdk.CfnOutput(this, 'VpcId', { value: this.vpc.vpcId });
    new cdk.CfnOutput(this, 'WorkstationSgId', {
      value: this.workstationSg.securityGroupId,
    });
  }
}
