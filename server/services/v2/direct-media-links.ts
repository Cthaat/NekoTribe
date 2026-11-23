import type { Connection } from 'oracledb';
import direct from '../../../specifications/requirements/direct-message-extras.json';
import legacy from '../../../specifications/requirements/media-private-read.json';
import { v2One } from '~/server/utils/v2';

export function isMissingDirectExtras(error: unknown) {
  return typeof error === 'object' && error !== null &&
    (('errorNum' in error && error.errorNum === 942) || ('code' in error && error.code === 'ORA-00942'));
}

export async function hasNoDirectExtrasTable(connection: Connection, presenceQuery: string) {
  const schema = await v2One(connection, "SELECT USER AS USER_NAME, SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS SCHEMA_NAME FROM dual");
  return !!schema?.USER_NAME && schema.USER_NAME === schema.SCHEMA_NAME && !await v2One(connection, presenceQuery);
}

async function hasNoDirectMediaTable(connection: Connection, error: unknown) {
  return isMissingDirectExtras(error) && await hasNoDirectExtrasTable(connection, direct.sql.attachment_table_present);
}

export async function referencedByDirectMessage(connection: Connection, mediaId: number) {
  try {
    return !!await v2One(connection,direct.sql.asset_is_linked,{media_id:mediaId});
  } catch (error) {
    if (await hasNoDirectMediaTable(connection,error)) return false;
    throw error;
  }
}

export async function readPrivateMediaAccess(connection: Connection, viewerId: number, mediaId: number) {
  const params = {viewer_id:viewerId,media_id:mediaId};
  try {
    return await v2One(connection,direct.sql.private_media_read,params);
  } catch (error) {
    if (await hasNoDirectMediaTable(connection,error)) return v2One(connection,legacy.query,params);
    throw error;
  }
}
