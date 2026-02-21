#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { NetworkStack } from '../lib/stacks/network-stack';
import { StorageStack } from '../lib/stacks/storage-stack';
import { DatabaseStack } from '../lib/stacks/database-stack';
import { AuthStack } from '../lib/stacks/auth-stack';
import { ComputeStack } from '../lib/stacks/compute-stack';
import { ENV, PREFIX, TAGS } from '../lib/config/constants';

const app = new cdk.App();

const env: cdk.Environment = {
  account: ENV.ACCOUNT,
  region: ENV.REGION,
};

const network = new NetworkStack(app, `${PREFIX}-network`, { env });

const storage = new StorageStack(app, `${PREFIX}-storage`, {
  env,
  vpc: network.vpc,
});

const database = new DatabaseStack(app, `${PREFIX}-database`, { env });

const auth = new AuthStack(app, `${PREFIX}-auth`, {
  env,
  dataBucket: storage.dataBucket,
  eidTable: database.eidTable,
});

new ComputeStack(app, `${PREFIX}-compute`, {
  env,
  vpc: network.vpc,
  workstationSg: network.workstationSg,
  dataBucket: storage.dataBucket,
  kmsKey: storage.kmsKey,
  eidTable: database.eidTable,
  userPool: auth.userPool,
});

// Apply tags to all stacks
for (const [key, value] of Object.entries(TAGS)) {
  cdk.Tags.of(app).add(key, value);
}
