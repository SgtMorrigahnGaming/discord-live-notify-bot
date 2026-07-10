const db = require('../db');
const epicClient = require('./epicClient');
const gamerPowerClient = require('./gamerPowerClient');
const { announceFreeGame } = require('./announcer');
const logger = require('../utils/logger');
const config = require('../config');

let running = false;

async function fetchForSource(source) {
  try {
    if (source === 'epic') return await epicClient.fetchCurrentFreeGames();
    return await gamerPowerClient.fetchGiveaways(source);
  } catch (err) {
    logger.error(`Free games: failed to fetch source ${source}:`, err.message);
    return [];
  }
}

async function pollOnce(client) {
  if (running) return;
  running = true;
  try {
    const sources = db.listActiveFreeGamesSources();
    if (sources.length === 0) return;

    let announced = 0;

    for (const source of sources) {
      const games = await fetchForSource(source);
      const subs = db.listGuildSubsForFreeGamesSource(source);
      if (subs.length === 0) continue;

      for (const game of games) {
        if (!game.externalId || !game.title) continue;
        if (db.hasAnnouncedFreeGame(source, game.externalId)) continue;

        db.markFreeGameAnnounced(source, game.externalId);
        for (const sub of subs) {
          await announceFreeGame(client, sub, source, game);
        }
        announced++;
      }
    }

    if (announced > 0) {
      logger.info(`Free games: announced ${announced} new giveaway(s) across subscribed guilds`);
    }
  } catch (err) {
    logger.error('Free games poll error:', err);
  } finally {
    running = false;
  }
}

function start(client) {
  logger.info(`Starting free games poller (every ${config.freegames.pollIntervalMs / 1000}s)`);
  pollOnce(client);
  setInterval(() => pollOnce(client), config.freegames.pollIntervalMs);
}

module.exports = { start, pollOnce };
