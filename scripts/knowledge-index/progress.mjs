const intervalMs = 10000;

export function indexProgress(mode, {write = console.error, now = () => performance.now()} = {}) {
  let previousStage;
  let reportedAt = 0;
  return ({stage, sources, points, reused}) => {
    const time = now();
    if (stage === previousStage && time - reportedAt < intervalMs) return;
    previousStage = stage;
    reportedAt = time;
    write(JSON.stringify({type:'index-progress',mode,stage,sources,points,reused}));
  };
}
