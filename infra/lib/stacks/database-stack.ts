import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';
import { DYNAMO } from '../config/constants';

export class DatabaseStack extends cdk.Stack {
  public readonly eidTable: dynamodb.Table;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // EID mapping table: project_id (PK) + eid (SK) -> internal_id, s3_key, file_size
    this.eidTable = new dynamodb.Table(this, 'EidTable', {
      tableName: DYNAMO.TABLE_NAME,
      partitionKey: { name: 'project_id', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'eid', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // GSI for reverse lookup: internal_id -> project_id + eid
    this.eidTable.addGlobalSecondaryIndex({
      indexName: DYNAMO.GSI_NAME,
      partitionKey: { name: 'internal_id', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // Outputs
    new cdk.CfnOutput(this, 'EidTableName', {
      value: this.eidTable.tableName,
    });
    new cdk.CfnOutput(this, 'EidTableArn', {
      value: this.eidTable.tableArn,
    });
  }
}
