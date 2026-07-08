const db = require('../db');
const youtubeClient = require('./youtubeClient');
const { announceYoutubeVideo } = require('./announcer');
const logger = require('../utils/logger');
const config = require('../config');

let running = false;

// Small concurrency limiter so we don't fire off hundreds of simultaneous requests
async function mapWithConcurrency(items, limit, fn) {
  const results = [];
  let i = 0;
  async function worker() {
    while (i < items.length) {
      const idx = i++;
      results[idx] = await fn(items[idx]).catch(err => {
        logger.error(`YouTube poll item error (${items[idx]}):`, err.message);
        return null;
      });
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

async function pollOnce(client) {
  if (running) return;
  running = true;
  try {
    const channelIds = db.listAllUniqueYoutubeChannels();
    if (channelIds.length === 0) return;

    let announced = 0;

    await mapWithConcurrency(channelIds, 5, async (channelId) => {
      const result = await youtubeClient.getLatestVideo(channelId);
      if (!result || !result.latest) return;

      const state = db.getYoutubeState(channelId);
      const { videoId } = result.latest;

      // First time we see this channel: just record the current latest video, don't spam-announce it
      if (!state || !state.initialized) {
        db.setYoutubeState(channelId, videoId);
        return;
      }

      if (state.last_video_id !== videoId) {
        db.setYoutubeState(channelId, videoId);
        const subs = db.listGuildSubsForYoutubeChannel(channelId);
        for (const sub of subs) {
          await announceYoutubeVideo(client, sub, result.latest);
        }
        announced++;
      }
    });

    if (announced > 0) {
      logger.info(`YouTube: announced ${announced} new video(s) across subscribed guilds`);
    }

    db.pruneOrphanYoutubeState();
  } catch (err) {
    logger.error('YouTube poll error:', err);
  } finally {
    running = false;
  }
}

function start(client) {
  logger.info(`Starting YouTube poller (every ${config.youtube.pollIntervalMs / 1000}s)`);
  pollOnce(client);
  setInterval(() => pollOnce(client), config.youtube.pollIntervalMs);
}

module.exports = { start, pollOnce };
