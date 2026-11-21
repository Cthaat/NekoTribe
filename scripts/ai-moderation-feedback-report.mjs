import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const contract = JSON.parse(readFileSync(
  new URL('../specifications/requirements/ai-moderation-feedback.json', import.meta.url),
  'utf8',
));
const fields = ['model_id', 'model_version', 'config_revision', 'rating', 'count'];
const profileId = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

function validVersion(value) {
  return value === null || (typeof value === 'string' && value.length > 0 &&
    [...value].length <= 128 && value.isWellFormed() && !/\p{Cc}/u.test(value));
}

function positiveInteger(value, limit = Number.MAX_SAFE_INTEGER) {
  return Number.isSafeInteger(value) && value > 0 && value <= limit;
}

function textOrder(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function summarizeModerationFeedback(rows) {
  if (!Array.isArray(rows)) throw new Error('Expected aggregate rows as a JSON array.');
  const byModel = new Map();
  for (const row of rows) {
    if (!row || typeof row !== 'object' || Object.keys(row).length !== fields.length ||
      !fields.every(field => Object.hasOwn(row, field)) ||
      typeof row.model_id !== 'string' || !profileId.test(row.model_id) ||
      !validVersion(row.model_version) || !positiveInteger(row.config_revision, 999999999999999) ||
      !contract.ratings.includes(row.rating) || !positiveInteger(row.count)) {
      throw new Error('Invalid aggregate row.');
    }
    const { model_id, model_version, config_revision, rating, count } = row;
    const key = JSON.stringify([model_id, model_version, config_revision]);
    let entry = byModel.get(key);
    if (!entry) {
      entry = {
        model_id, model_version, config_revision,
        ratings: Object.fromEntries(contract.ratings.map(value => [value, 0])),
        sample_size: 0,
      };
      byModel.set(key, entry);
    }
    if (entry.ratings[rating] !== 0) throw new Error('Duplicate aggregate row.');
    if (!positiveInteger(entry.sample_size + count)) throw new Error('Aggregate count is too large.');
    entry.ratings[rating] = count;
    entry.sample_size += count;
  }
  const groups = [...byModel.values()].sort((a, b) =>
    textOrder(a.model_id, b.model_id) || a.config_revision - b.config_revision ||
    textOrder(a.model_version ?? '', b.model_version ?? '')
  );
  return {
    revision: contract.revision,
    groups: groups.map(entry => ({ ...entry, helpful_rate: entry.ratings.helpful / entry.sample_size })),
  };
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    const [input, ...rest] = process.argv.slice(2);
    if (!input || rest.length) throw new Error('Use --print-query or provide a single aggregate JSON file.');
    if (input === '--print-query') {
      console.log(contract.queries.aggregate);
    } else {
      let rows;
      try {
        rows = JSON.parse(readFileSync(input, 'utf8'));
      } catch {
        throw new Error('Could not read aggregate JSON.');
      }
      console.log(JSON.stringify(summarizeModerationFeedback(rows), null, 2));
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
