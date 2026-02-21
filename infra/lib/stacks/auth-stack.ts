import * as cdk from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import { Construct } from 'constructs';
import { PREFIX, COGNITO as COGNITO_CONFIG, PROJECTS, S3 } from '../config/constants';

export interface AuthStackProps extends cdk.StackProps {
  dataBucket: s3.IBucket;
  eidTable: dynamodb.ITable;
}

export class AuthStack extends cdk.Stack {
  public readonly userPool: cognito.UserPool;
  public readonly userPoolClient: cognito.UserPoolClient;
  public readonly identityPool: cognito.CfnIdentityPool;

  constructor(scope: Construct, id: string, props: AuthStackProps) {
    super(scope, id, props);

    // Cognito User Pool for researcher authentication
    this.userPool = new cognito.UserPool(this, 'UserPool', {
      userPoolName: COGNITO_CONFIG.USER_POOL_NAME,
      selfSignUpEnabled: false,
      signInAliases: { email: true },
      autoVerify: { email: true },
      mfa: cognito.Mfa.OPTIONAL,
      mfaSecondFactor: { sms: false, otp: true },
      passwordPolicy: {
        minLength: 12,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true,
        tempPasswordValidity: cdk.Duration.days(7),
      },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      standardAttributes: {
        email: { required: true, mutable: false },
        fullname: { required: true, mutable: true },
      },
      customAttributes: {
        institution: new cognito.StringAttribute({ mutable: true, maxLen: 256 }),
      },
    });

    // User Pool Client
    this.userPoolClient = this.userPool.addClient('WebClient', {
      userPoolClientName: `${PREFIX}-web-client`,
      authFlows: {
        userSrp: true,
      },
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: ['https://localhost:3000/callback'],
      },
      accessTokenValidity: cdk.Duration.hours(1),
      refreshTokenValidity: cdk.Duration.days(30),
      idTokenValidity: cdk.Duration.hours(1),
    });

    // Cognito Identity Pool
    this.identityPool = new cognito.CfnIdentityPool(this, 'IdentityPool', {
      identityPoolName: `${PREFIX}_identity_pool`,
      allowUnauthenticatedIdentities: false,
      cognitoIdentityProviders: [
        {
          clientId: this.userPoolClient.userPoolClientId,
          providerName: this.userPool.userPoolProviderName,
        },
      ],
    });

    // Authenticated role (base)
    const authenticatedRole = new iam.Role(this, 'AuthenticatedRole', {
      roleName: `${PREFIX}-cognito-authenticated`,
      assumedBy: new iam.FederatedPrincipal(
        'cognito-identity.amazonaws.com',
        {
          StringEquals: {
            'cognito-identity.amazonaws.com:aud': this.identityPool.ref,
          },
          'ForAnyValue:StringLike': {
            'cognito-identity.amazonaws.com:amr': 'authenticated',
          },
        },
        'sts:AssumeRoleWithWebIdentity'
      ),
    });

    // Attach identity pool roles
    new cognito.CfnIdentityPoolRoleAttachment(this, 'IdentityPoolRoles', {
      identityPoolId: this.identityPool.ref,
      roles: {
        authenticated: authenticatedRole.roleArn,
      },
      roleMappings: {
        userPool: {
          identityProvider: `${this.userPool.userPoolProviderName}:${this.userPoolClient.userPoolClientId}`,
          type: 'Token',
          ambiguousRoleResolution: 'AuthenticatedRole',
        },
      },
    });

    // Create per-project groups with scoped IAM roles
    for (const projectId of PROJECTS) {
      const projectRole = new iam.Role(this, `ProjectRole-${projectId}`, {
        roleName: `${PREFIX}-${projectId}-role`,
        assumedBy: new iam.FederatedPrincipal(
          'cognito-identity.amazonaws.com',
          {
            StringEquals: {
              'cognito-identity.amazonaws.com:aud': this.identityPool.ref,
            },
            'ForAnyValue:StringLike': {
              'cognito-identity.amazonaws.com:amr': 'authenticated',
            },
          },
          'sts:AssumeRoleWithWebIdentity'
        ),
      });

      // S3: read access to CRAM data and reference genome
      projectRole.addToPolicy(
        new iam.PolicyStatement({
          actions: ['s3:GetObject'],
          resources: [
            props.dataBucket.arnForObjects(`${S3.PREFIXES.CRAM}*`),
            props.dataBucket.arnForObjects(`${S3.PREFIXES.REFERENCE}*`),
          ],
        })
      );

      // DynamoDB: query only for their own project
      projectRole.addToPolicy(
        new iam.PolicyStatement({
          actions: ['dynamodb:Query', 'dynamodb:GetItem'],
          resources: [
            props.eidTable.tableArn,
            `${props.eidTable.tableArn}/index/*`,
          ],
          conditions: {
            'ForAllValues:StringEquals': {
              'dynamodb:LeadingKeys': [projectId],
            },
          },
        })
      );

      // Create the Cognito group mapped to this role
      new cognito.CfnUserPoolGroup(this, `Group-${projectId}`, {
        userPoolId: this.userPool.userPoolId,
        groupName: projectId,
        description: `Researchers in ${projectId}`,
        roleArn: projectRole.roleArn,
      });
    }

    // Outputs
    new cdk.CfnOutput(this, 'UserPoolId', {
      value: this.userPool.userPoolId,
    });
    new cdk.CfnOutput(this, 'UserPoolClientId', {
      value: this.userPoolClient.userPoolClientId,
    });
    new cdk.CfnOutput(this, 'IdentityPoolId', {
      value: this.identityPool.ref,
    });
  }
}
