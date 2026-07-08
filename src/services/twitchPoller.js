const db = require('../db');
const twitchClient = require('./twitchClient');
const { announceTwitchLive } = require('./announcer');
const logger = require('../utils/logger');
const config = require('../config');

let running = false;

async function pollOnce(client) {
  if (running) return; // avoid overlapping runs if a poll takes longer than the interval
  running = true;
  try {
    const streamers = db.listAllUniqueTwitchStreamers();
    if (streamers.length === 0) return;

    const liveStreams = await twitchClient.getLiveStreams(streamers);

    // Only fetch user/profile info for streamers that are actually live right now (keeps calls minimal)
    const newlyLive = [];
    for (const login of streamers) {
      const state = db.getTwitchState(login);
      const stream = liveStreams.get(login);
      const wasLive = !!(state && state.is_live);
      const isLive = !!stream;

      if (isLive && (!wasLive || state.last_stream_id !== stream.id)) {
        newlyLive.push({ login, stream });
      }
      db.setTwitchState(login, isLive, stream ? stream.id : state?.last_stream_id ?? null);
    }

    if (newlyLive.length > 0) {
      const users = await twitchClient.getUsers(newlyLive.map(n => n.login));
      for (const { login, stream } of newlyLive) {
        const user = users.get(login);
        const subs = db.listGuildSubsForStreamer(login);
        for (const sub of subs) {
          await announceTwitchLive(client, sub, stream, user);
        }
      }
      logger.info(`Twitch: announced ${newlyLive.length} newly-live streamer(s) across their subscribed guilds`);
    }

    db.pruneOrphanTwitchState();
  } catch (err) {
    logger.error('Twitch poll error:', err);
  } finally {
    running = false;
  }
}

function start(client) {
  if (!config.twitch.clientId || !config.twitch.clientSecret) {
    logger.warn('Twitch credentials not set (TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET) — Twitch polling disabled.');
    return;
  }
  logger.info(`Starting Twitch poller (every ${config.twitch.pollIntervalMs / 1000}s)`);
  pollOnce(client);
  setInterval(() => pollOnce(client), config.twitch.pollIntervalMs);
}

module.exports = { start, pollOnce };
