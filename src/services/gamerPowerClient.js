const logger = require('../utils/logger');

const ENDPOINT = 'https://www.gamerpower.com/api/giveaways';

const PLATFORM_MAP = {
  steam: 'steam',
  gog: 'gog',
};

/** Returns currently-live giveaways for a platform, normalized: { externalId, title, description, url, image }. */
async function fetchGiveaways(source) {
  const platform = PLATFORM_MAP[source];
  if (!platform) throw new Error(`Unknown GamerPower source: ${source}`);

  const res = await fetch(`${ENDPOINT}?platform=${platform}&type=game`, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; DiscordLiveNotifyBot/1.0)' },
  });
  if (!res.ok) {
    logger.warn(`GamerPower fetch failed for ${source}: HTTP ${res.status}`);
    return [];
  }
  const body = await res.json();
  if (!Array.isArray(body)) {
    logger.warn(`GamerPower: unexpected response shape for ${source} (expected an array)`);
    return [];
  }

  return body
    .filter(g => g.status === 'active' || !g.status) // be lenient — field naming has shifted before across API versions
    .map(g => ({
      externalId: String(g.id),
      title: g.title,
      description: g.description || null,
      url: g.open_giveaway_url || g.gamerpower_url || 'https://www.gamerpower.com',
      image: g.image || g.thumbnail || null,
    }));
}

module.exports = { fetchGiveaways };
