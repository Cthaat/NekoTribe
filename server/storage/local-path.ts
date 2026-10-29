import {StorageHttpError} from './http';
import fs from 'node:fs/promises';
import path from 'node:path';

export function normalizeLocalStorageKey(key:string):string {
  const normalized=key.replace(/\\/g,'/');
  const parts=normalized.split('/');
  if(parts.some(part=>!part||part==='.'||part==='..'||/[\x00-\x1f\x7f<>:"|?*]/.test(part)||/[. ]$/.test(part)||/^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]|CONIN\$|CONOUT\$)$/i.test(part.split('.')[0]!.replace(/ +$/,'')))) {
    throw new StorageHttpError(400,'非法存储路径');
  }
  return normalized;
}

async function checkedDirectory(directory:string,create:boolean):Promise<void> {
  let stat;
  try { stat=await fs.lstat(directory); }
  catch(error) {
    if(!create||(error as NodeJS.ErrnoException).code!=='ENOENT')throw error;
    try { await fs.mkdir(directory); }
    catch(caught) { if((caught as NodeJS.ErrnoException).code!=='EEXIST')throw caught; }
    stat=await fs.lstat(directory);
  }
  if(stat.isSymbolicLink()||!stat.isDirectory())throw new StorageHttpError(400,'非法存储路径');
}

async function walkDirectories(root:string,parts:string[],create:boolean):Promise<string> {
  // The configured root is trusted and may itself be an administrator mount.
  if(create)await fs.mkdir(root,{recursive:true});
  let current=await fs.realpath(root);
  for(const part of parts) {
    current=path.join(current,part);
    await checkedDirectory(current,create);
  }
  return current;
}

export async function ensureLocalStorageDirectory(root:string,key:string):Promise<string> {
  return await walkDirectories(root,normalizeLocalStorageKey(key).split('/'),true);
}

export async function resolveLocalStoragePath(root:string,key:string,createParents=false):Promise<string> {
  const parts=normalizeLocalStorageKey(key).split('/');
  const leaf=parts.pop()!;
  const parent=await walkDirectories(root,parts,createParents);
  const target=path.join(parent,leaf);
  try {
    const stat=await fs.lstat(target);
    if(stat.isSymbolicLink())throw new StorageHttpError(400,'非法存储路径');
    if(!stat.isFile())throw new StorageHttpError(404,'文件不存在');
  } catch(error) { if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error; }
  return target;
}
