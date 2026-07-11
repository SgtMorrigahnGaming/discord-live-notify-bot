const db = require('../db');
const logger = require('../utils/logger');

function register(client) {
  client.on('guildDelete', (guild) => {
    try {
      db.purgeGuildData(guild.id);
      logger.info(`Removed from guild "${guild.name}" (${guild.id}) — purged its stored data.`);
    } catch (err) {
      logger.error(`Failed to purge data for removed guild ${guild.id}:`, err);
    }
  });

  logger.info('Guild cleanup handler registered');
}

module.exports = { register };
