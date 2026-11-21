import { delimiter, dirname } from 'node:path';

export function launcherEnvironment(env) {
  if (process.platform !== 'win32') return env;
  // Yarn puts a node.cmd shim first on PATH. A batch launcher calling another
  // batch file transfers control instead of returning to its next command.
  const path = Object.keys(env).find(name => name.toUpperCase() === 'PATH') ?? 'PATH';
  return { ...env, [path]: [dirname(process.execPath), env[path]].filter(Boolean).join(delimiter) };
}
