import { DynamoDBClient, GetItemCommand } from '@aws-sdk/client-dynamodb';

const ddb = new DynamoDBClient({});
const TABLE_NAME = process.env.TABLE_NAME!;
const BUCKET_NAME = process.env.BUCKET_NAME!;

interface EidResolverEvent {
  project_id: string;
  eid: string;
}

interface EidResolverResponse {
  project_id: string;
  eid: string;
  internal_id: string;
  s3_key: string;
  s3_uri: string;
}

export const handler = async (event: EidResolverEvent): Promise<EidResolverResponse> => {
  const { project_id, eid } = event;

  if (!project_id || !eid) {
    throw new Error('project_id and eid are required');
  }

  const result = await ddb.send(
    new GetItemCommand({
      TableName: TABLE_NAME,
      Key: {
        project_id: { S: project_id },
        eid: { S: eid },
      },
    })
  );

  if (!result.Item) {
    throw new Error(`EID mapping not found: project=${project_id}, eid=${eid}`);
  }

  const internal_id = result.Item.internal_id?.S;
  if (!internal_id) {
    throw new Error(`internal_id missing for project=${project_id}, eid=${eid}`);
  }

  const s3_key = result.Item.s3_key?.S ?? `internal/cram/${internal_id}.cram`;

  return {
    project_id,
    eid,
    internal_id,
    s3_key,
    s3_uri: `s3://${BUCKET_NAME}/${s3_key}`,
  };
};
