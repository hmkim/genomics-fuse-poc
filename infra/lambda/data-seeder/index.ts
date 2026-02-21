import { DynamoDBClient, BatchWriteItemCommand } from '@aws-sdk/client-dynamodb';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';

const ddb = new DynamoDBClient({});
const s3 = new S3Client({});
const TABLE_NAME = process.env.TABLE_NAME!;
const BUCKET_NAME = process.env.BUCKET_NAME!;

interface InlineData {
  [projectId: string]: {
    [eid: string]: string; // internal_id
  };
}

interface DataSeederEvent {
  source: 'INLINE' | 'S3';
  inline_data?: InlineData;
  s3_key?: string;
}

interface DataSeederResponse {
  items_written: number;
  projects: string[];
}

// DynamoDB BatchWriteItem supports max 25 items per request
const BATCH_SIZE = 25;

async function loadFromS3(key: string): Promise<InlineData> {
  const result = await s3.send(
    new GetObjectCommand({
      Bucket: BUCKET_NAME,
      Key: key,
    })
  );
  const body = await result.Body!.transformToString('utf-8');
  return JSON.parse(body);
}

export const handler = async (event: DataSeederEvent): Promise<DataSeederResponse> => {
  let data: InlineData;

  if (event.source === 'INLINE') {
    if (!event.inline_data) {
      throw new Error('inline_data is required when source is INLINE');
    }
    data = event.inline_data;
  } else if (event.source === 'S3') {
    if (!event.s3_key) {
      throw new Error('s3_key is required when source is S3');
    }
    data = await loadFromS3(event.s3_key);
  } else {
    throw new Error(`Unknown source: ${event.source}. Use INLINE or S3.`);
  }

  const projects: string[] = [];
  let itemsWritten = 0;

  // Build write requests from the mapping data
  const writeRequests: Array<{
    PutRequest: {
      Item: Record<string, { S: string } | { N: string }>;
    };
  }> = [];

  for (const [projectId, mappings] of Object.entries(data)) {
    projects.push(projectId);

    for (const [eid, internalId] of Object.entries(mappings)) {
      writeRequests.push({
        PutRequest: {
          Item: {
            project_id: { S: projectId },
            eid: { S: eid },
            internal_id: { S: internalId },
            s3_key: { S: `internal/cram/${internalId}.cram` },
            created_at: { S: new Date().toISOString() },
          },
        },
      });
    }
  }

  // Write in batches of 25
  for (let i = 0; i < writeRequests.length; i += BATCH_SIZE) {
    const batch = writeRequests.slice(i, i + BATCH_SIZE);

    let unprocessed = batch;
    let retries = 0;

    while (unprocessed.length > 0 && retries < 5) {
      const result = await ddb.send(
        new BatchWriteItemCommand({
          RequestItems: {
            [TABLE_NAME]: unprocessed,
          },
        })
      );

      const remaining = result.UnprocessedItems?.[TABLE_NAME];
      if (remaining && remaining.length > 0) {
        unprocessed = remaining as typeof batch;
        retries++;
        // Exponential backoff
        await new Promise((r) => setTimeout(r, 100 * Math.pow(2, retries)));
      } else {
        itemsWritten += unprocessed.length;
        unprocessed = [];
      }
    }

    if (unprocessed.length > 0) {
      throw new Error(
        `Failed to write ${unprocessed.length} items after ${retries} retries`
      );
    }
  }

  return {
    items_written: itemsWritten,
    projects,
  };
};
