const logger = require('../utils/logger');

const ENDPOINT = 'https://www.gamerpower.com/api/giveaways';

const PLATFORM_MAP = {
  steam: 'steam',
  gog: 'gog',
  'drm-free': 'drm-free',
  ps4: 'ps4',
  ps5: 'ps5',
  'xbox-series-xs': 'xbox-series-xs',
  'xbox-one': 'xbox-one',
  switch: 'switch',
  android: 'android',
  ios: 'ios',
  itchio: 'itchio',
};

function truncate(text, max = 200) {
  if (!text) return '(empty body)';
  const clean = text.replace(/\s+/g, ' ').trim();
  return clean.length > max ? `${clean.slice(0, max)}…` : clean;
}

/** Returns currently-live giveaways for a platform, normalized: { externalId, title, description, url, image }. */
async function fetchGiveaways(source) {
  const platform = PLATFORM_MAP[source];
  if (!platform) throw new Error(`Unknown GamerPower source: ${source}`);

  // No custom User-Agent: a self-identifying bot UA can trigger Cloudflare
  // bot-management on GamerPower's side and return a challenge page instead
  // of JSON. A plain, header-less request matches known-working integrations.
  const res = await fetch(`${ENDPOINT}?platform=${platform}&type=game`);
  const rawText = await res.text();

  if (!res.ok) {
    logger.warn(`GamerPower fetch failed for ${source}: HTTP ${res.status} — body: ${truncate(rawText)}`);
    return [];
  }

  let body;
  try {
    body = JSON.parse(rawText);
  } catch (err) {
    logger.warn(`GamerPower: response for ${source} was not valid JSON — body: ${truncate(rawText)}`);
    return [];
  }

  if (!Array.isArray(body)) {
    // GamerPower returns this envelope (not an array) when nothing matches
    // the query — a normal, expected "zero results" case, not an error.
    if (body && typeof body === 'object' && 'status' in body && 'status_message' in body) {
      logger.info(`GamerPower: no active giveaways for ${source} (${body.status_message})`);
      return [];
    }
    logger.warn(`GamerPower: unexpected response shape for ${source} (expected an array) — body: ${truncate(rawText)}`);
    return [];
  }

  // Trust GamerPower's own server-side filtering (their docs state this
  // endpoint "returns all active giveaways") instead of re-filtering on a
  // guessed status value here — that guess previously dropped genuinely
  // active giveaways. Still log unrecognized status values for visibility.
  for (const g of body) {
    if (g.status && g.status !== 'active') {
      logger.info(`GamerPower: giveaway ${g.id} (${g.title}) for ${source} has status="${g.status}" — including anyway`);
    }
  }

  const giveaways = body
    .map(g => ({
      externalId: String(g.id),
      title: g.title,
      description: g.description || null,
      url: g.open_giveaway_url || g.gamerpower_url || 'https://www.gamerpower.com',
      image: g.image || g.thumbnail || null,
    }));

  logger.info(`GamerPower: fetched ${body.length} raw giveaway(s) for ${source}, ${giveaways.length} matched after filtering`);

  return giveaways;
}

module.exports = { fetchGiveaways };
