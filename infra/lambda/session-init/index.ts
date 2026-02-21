import { DynamoDBClient, QueryCommand } from '@aws-sdk/client-dynamodb';

const ddb = new DynamoDBClient({});
const TABLE_NAME = process.env.TABLE_NAME!;
const BUCKET_NAME = process.env.BUCKET_NAME!;

interface SessionInitEvent {
  project_id: string;
  user_id: string;
}

interface MappingEntry {
  eid: string;
  internal_id: string;
  symlink_source: string;
  symlink_target: string;
}

interface SessionInitResponse {
  project_id: string;
  user_id: string;
  mappings: MappingEntry[];
  mount_config: {
    bucket: string;
    project_id: string;
    mount_point: string;
    cram_prefix: string;
  };
}

export const handler = async (event: SessionInitEvent): Promise<SessionInitResponse> => {
  const { project_id, user_id } = event;

  if (!project_id || !user_id) {
    throw new Error('project_id and user_id are required');
  }

  const mappings: MappingEntry[] = [];
  let lastKey: Record<string, any> | undefined;

  // Paginated query for all EIDs in the project
  do {
    const result = await ddb.send(
      new QueryCommand({
        TableName: TABLE_NAME,
        KeyConditionExpression: 'project_id = :pid',
        ExpressionAttributeValues: {
          ':pid': { S: project_id },
        },
        ExclusiveStartKey: lastKey,
      })
    );

    for (const item of result.Items ?? []) {
      const eid = item.eid?.S;
      const internal_id = item.internal_id?.S;
      if (!eid || !internal_id) continue;

      const s3_key = item.s3_key?.S ?? `internal/cram/${internal_id}.cram`;

      // CRAM file
      mappings.push({
        eid,
        internal_id,
        symlink_source: `${eid}.cram`,
        symlink_target: s3_key,
      });

      // CRAI index file
      mappings.push({
        eid,
        internal_id,
        symlink_source: `${eid}.cram.crai`,
        symlink_target: `${s3_key}.crai`,
      });
    }

    lastKey = result.LastEvaluatedKey;
  } while (lastKey);

  return {
    project_id,
    user_id,
    mappings,
    mount_config: {
      bucket: BUCKET_NAME,
      project_id,
      mount_point: `/mnt/project/${project_id}`,
      cram_prefix: 'internal/cram/',
    },
  };
};
