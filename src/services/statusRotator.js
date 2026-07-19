const { ActivityType } = require('discord.js');
const logger = require('../utils/logger');

const ROTATE_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

const STATUSES = [
  '📺 Watching Twitch & YouTube',
  '🔔 Watching Live Streams',
  '🎁 Watching Free Games',
  '🎉 Watching Giveaways',
  '🏷️ Watching Reaction Roles',
  '🌐 Watching bot.morrigahngaming.no',
];

let index = 0;
let timer = null;

function applyStatus(client) {
  const text = STATUSES[index];
  client.user.setPresence({
    activities: [{ name: text, type: ActivityType.Custom, state: text }],
    status: 'online',
  });
  index = (index + 1) % STATUSES.length;
}

function start(client) {
  if (timer) return; // already running
  applyStatus(client);
  timer = setInterval(() => applyStatus(client), ROTATE_INTERVAL_MS);
  logger.info(`Status rotator started (${STATUSES.length} statuses, every ${ROTATE_INTERVAL_MS / 60000}m)`);
}

module.exports = { start };
