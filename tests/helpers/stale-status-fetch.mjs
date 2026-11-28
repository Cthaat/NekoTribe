// Preloaded only by the stale-revision CLI subprocess. Keep its real polling loop and deadline.
globalThis.fetch = async (url, options) => {
  options.signal.throwIfAborted();
  if (url.pathname !== '/stale/api/v2/ai/availability') throw Error('Unexpected fixture endpoint');
  return Response.json({ code: 200, data: { model_config_revision: 4 } });
};
