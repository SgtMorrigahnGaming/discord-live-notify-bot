const { EmbedBuilder } = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');
const modLogHandler = require('./modLogHandler');

// How long a message "counts" toward a cross-channel match before it ages out.
const WINDOW_MS = 3 * 60 * 1000; // 3 minutes (within the agreed 2-5 min range)
const CLEANUP_INTERVAL_MS = 60 * 1000;
const URL_REGEX = /https?:\/\/\S+/gi;

// key: `${guildId}:${authorId}:${fingerprint}` -> Map(channelId -> { messageId, timestamp })
const tracker = new Map();

function normalizeText(content) {
  return content.trim().toLowerCase().replace(/\s+/g, ' ');
}

// Same message = same author AND (exact normalized text match OR shared link/URL).
// Returns null if the message has neither text nor a link to fingerprint on.
function fingerprint(content) {
  const urls = content.match(URL_REGEX);
  if (urls && urls.length > 0) {
    return 'link:' + urls.map((u) => u.toLowerCase()).sort().join(',');
  }
  const text = normalizeText(content);
  if (text) return 'text:' + text;
  return null;
}

function pruneExpired(entry, now) {
  for (const [channelId, data] of entry) {
    if (now - data.timestamp > WINDOW_MS) entry.delete(channelId);
  }
}

async function handleTrigger(client, message, entry, config) {
  const guild = message.guild;
  const channelRefs = [...entry.entries()]; // [[channelId, {messageId, timestamp}], ...]

  // Delete every tracked copy first, so the spam stops spreading even if the timeout fails.
  await Promise.all(
    channelRefs.map(async ([channelId, data]) => {
      const channel = await client.channels.fetch(channelId).catch(() => null);
      const msg = channel ? await channel.messages.fetch(data.messageId).catch(() => null) : null;
      if (msg) await msg.delete().catch(() => {});
    })
  );

  const timeoutMs = config.spam_timeout_minutes * 60 * 1000;
  const member = await guild.members.fetch(message.author.id).catch(() => null);
  let timeoutApplied = false;
  if (member) {
    await member.timeout(timeoutMs, 'Automated: cross-channel spam detected').then(() => {
      timeoutApplied = true;
    }).catch((err) => {
      logger.warn(`SpamDetector: couldn't time out ${message.author.tag} in ${guild.name}:`, err.message);
    });
  }

  const embed = new EmbedBuilder()
    .setColor(0xc0392b)
    .setTitle('🚨 Cross-channel spam detected')
    .setDescription(`${message.author.tag} (${message.author.id})`)
    .addFields(
      { name: 'Channels', value: channelRefs.map(([id]) => `<#${id}>`).join(', ') },
      { name: 'Action taken', value: timeoutApplied ? `Deleted messages + timed out for ${config.spam_timeout_minutes}m` : 'Deleted messages (timeout failed — check my Moderate Members permission)' }
    )
    .setTimestamp();
  await modLogHandler.sendToCategory(client, guild.id, 'spam_channel_id', embed);
}

function register(client) {
  client.on('messageCreate', async (message) => {
    try {
      if (!message.guild || message.author.bot) return;

      const config = db.getModlogConfig(message.guild.id);
      if (!config || !config.spam_enabled) return;

      if (config.spam_exempt_role_ids.length > 0) {
        const member = message.member || (await message.guild.members.fetch(message.author.id).catch(() => null));
        if (member && member.roles.cache.some((r) => config.spam_exempt_role_ids.includes(r.id))) return;
      }

      const fp = fingerprint(message.content);
      if (!fp) return; // nothing fingerprintable (e.g. attachment-only message) — out of scope for v1

      const key = `${message.guild.id}:${message.author.id}:${fp}`;
      let entry = tracker.get(key);
      if (!entry) {
        entry = new Map();
        tracker.set(key, entry);
      }
      pruneExpired(entry, Date.now());
      entry.set(message.channel.id, { messageId: message.id, timestamp: Date.now() });

      if (entry.size >= config.spam_channel_threshold) {
        tracker.delete(key); // stop tracking immediately so this can't double-trigger
        await handleTrigger(client, message, entry, config);
      }
    } catch (err) {
      logger.error('SpamDetector: messageCreate handler error:', err);
    }
  });

  setInterval(() => {
    const now = Date.now();
    for (const [key, entry] of tracker) {
      pruneExpired(entry, now);
      if (entry.size === 0) tracker.delete(key);
    }
  }, CLEANUP_INTERVAL_MS).unref();

  logger.info('Spam detector registered');
}

module.exports = { register };
