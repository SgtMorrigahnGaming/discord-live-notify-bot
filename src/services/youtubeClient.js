const { XMLParser } = require('fast-xml-parser');
const logger = require('../utils/logger');

const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_' });

/**
 * Resolves a user-supplied channel reference (raw channel ID, @handle, /c/ URL, /user/ URL,
 * full channel URL, etc.) into a canonical UC... channel ID. Uses no API key — just scrapes
 * the public channel page for its canonical channelId, which YouTube always embeds.
 */
async function resolveChannelId(input) {
  const trimmed = input.trim();

  // Already looks like a channel ID
  if (/^UC[\w-]{22}$/.test(trimmed)) return trimmed;

  let path = trimmed;
  if (!/^https?:\/\//i.test(path)) {
    if (path.startsWith('@')) {
      path = `https://www.youtube.com/${path}`;
    } else if (path.startsWith('/')) {
      path = `https://www.youtube.com${path}`;
    } else {
      // bare name — try as a handle first
      path = `https://www.youtube.com/@${path}`;
    }
  }

  const res = await fetch(path, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; DiscordLiveNotifyBot/1.0)' },
  });
  if (!res.ok) return null;
  const html = await res.text();

  const match = html.match(/"channelId":"(UC[\w-]{22})"/) || html.match(/channel_id=(UC[\w-]{22})/);
  return match ? match[1] : null;
}

/** Fetches channel display name + latest video from the free public RSS feed. */
async function getLatestVideo(channelId) {
  const res = await fetch(`https://www.youtube.com/feeds/videos.xml?channel_id=${channelId}`, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; DiscordLiveNotifyBot/1.0)' },
  });
  if (!res.ok) {
    logger.warn(`YouTube RSS fetch failed for ${channelId}: HTTP ${res.status}`);
    return null;
  }
  const xml = await res.text();
  const data = parser.parse(xml);
  const feed = data?.feed;
  if (!feed) return null;

  const channelName = feed.author?.name || feed.title || channelId;
  const entries = Array.isArray(feed.entry) ? feed.entry : (feed.entry ? [feed.entry] : []);
  if (entries.length === 0) return { channelName, latest: null };

  const first = entries[0];
  const videoId = first['yt:videoId'];
  const thumbnail = first['media:group']?.['media:thumbnail']?.['@_url'];

  return {
    channelName,
    latest: {
      videoId,
      title: first.title,
      url: `https://www.youtube.com/watch?v=${videoId}`,
      published: first.published,
      thumbnail,
      channelName,
    },
  };
}

module.exports = { resolveChannelId, getLatestVideo };
