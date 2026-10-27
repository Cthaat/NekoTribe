import { randomInt } from 'node:crypto';

// Windows can allocate a Fetch-forbidden port (e.g. 3659) when listen(0) uses
// its dynamic range. Fetch's forbidden-port list ends below this high range.
// Ports may already be in use or OS-reserved, so choose another with a bound.
export async function listenForFetch(server, { choosePort = () => randomInt(49152, 65536), maxAttempts = 64 } = {}) {
  if (!Number.isSafeInteger(maxAttempts) || maxAttempts < 1) throw new RangeError('maxAttempts must be positive');
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      await new Promise((resolve, reject) => {
        const cleanup = () => { server.off('error', onError); server.off('listening', onListening); };
        const onError = error => { cleanup(); reject(error); };
        const onListening = () => { cleanup(); resolve(); };
        server.once('error', onError);
        server.once('listening', onListening);
        try { server.listen(choosePort(), '127.0.0.1'); }
        catch (error) { cleanup(); reject(error); }
      });
      return `http://127.0.0.1:${server.address().port}`;
    } catch (error) {
      if (!['EADDRINUSE', 'EACCES'].includes(error?.code) || attempt === maxAttempts - 1) throw error;
    }
  }
}
