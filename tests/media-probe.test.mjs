import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp, rm, rmdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { build } from 'esbuild';
import ffprobe from 'ffprobe-static';

const compiled = await build({entryPoints:['server/storage/media-probe.ts'],bundle:true,write:false,platform:'node',format:'esm'});
const { mediaProbeArgs, parseMediaProbe, pcmWaveDuration, probeRichMedia } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`
);

const binary = typeof ffprobe === 'string' ? ffprobe : ffprobe.path;

test('video probe uses the selected container and local input only', () => {
  const args = mediaProbeArgs('/controlled/upload', 'video/mp4');
  for (const [flag,value] of [['-i','/controlled/upload'],['-f','mov'],['-protocol_whitelist','file'],['-enable_drefs','0'],['-use_absolute_path','0']]) {
    assert.equal(args[args.indexOf(flag)+1], value);
  }
  assert.equal(mediaProbeArgs('/controlled/upload', 'application/octet-stream'), null);
});

test('media metadata rejects invalid dimensions and nonnegative limits', () => {
  assert.deepEqual(parseMediaProbe('{"streams":[{"codec_type":"video","width":640,"height":360}],"format":{"duration":"12.5"}}'),
    {width:640,height:360,duration:13});
  assert.deepEqual(parseMediaProbe('{"streams":[{"codec_type":"video","width":0,"height":2.7}],"format":{"duration":"-0.4"}}'),
    {width:null,height:null,duration:null});
});

async function waveFixture(t) {
  const dir = await mkdtemp(join(tmpdir(), 'neko-media-probe-'));
  const file = join(dir,'wave');
  t.after(async () => { await rm(file,{force:true}); await rmdir(dir); });
  const wav = Buffer.alloc(16044);
  Buffer.from('RIFF').copy(wav);
  wav.writeUInt32LE(16036,4);
  Buffer.from('WAVEfmt ').copy(wav,8);
  wav.writeUInt32LE(16,16);
  wav.writeUInt16LE(1,20);
  wav.writeUInt16LE(1,22);
  wav.writeUInt32LE(8000,24);
  wav.writeUInt32LE(16000,28);
  wav.writeUInt16LE(2,32);
  wav.writeUInt16LE(16,34);
  Buffer.from('data').copy(wav,36);
  wav.writeUInt32LE(16000,40);
  await writeFile(file,wav);
  return {file,wav};
}

test('PCM fallback only accepts a complete and coherent RIFF layout', async t => {
  const {file,wav} = await waveFixture(t);
  assert.equal(await pcmWaveDuration(file),1);
  assert.equal(await probeRichMedia(`${file}-absent`,file,'audio/wav'),null);
  await writeFile(file,wav.subarray(0,44));
  assert.equal(await pcmWaveDuration(file),null);
});

test('bundled probe reads a WAV from the same local staging path', {skip:!binary || !existsSync(binary)}, async t => {
  const {file} = await waveFixture(t);
  assert.deepEqual(await probeRichMedia(binary,file,'audio/wav'),{width:null,height:null,duration:1});
});
