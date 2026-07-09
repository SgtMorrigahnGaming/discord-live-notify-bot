const db = require('../db');
const emojiUtil = require('../utils/emoji');
const logger = require('../utils/logger');

function fillTemplate(template, vars) {
  if (!template) return null;
  let out = template;
  for (const [key, val] of Object.entries(vars)) {
    out = out.replaceAll(`{${key}}`, val ?? '');
  }
  return out;
}

async function resolveReactionContext(reaction, user) {
  if (user.bot) return null; // ignore the bot's own setup reaction, and any other bots

  if (reaction.partial) {
    try { await reaction.fetch(); } catch { return null; }
  }
  if (reaction.message.partial) {
    try { await reaction.message.fetch(); } catch { return null; }
  }

  const { message } = reaction;
  if (!message.guild) return null; // DMs have no guild

  const row = db.getReactionRole(message.id, reaction.emoji.id, reaction.emoji.name);
  if (!row) return null;

  const member = await message.guild.members.fetch(user.id).catch(() => null);
  if (!member) return null;

  return { row, member, guild: message.guild };
}

function register(client) {
  client.on('messageReactionAdd', async (reaction, user) => {
    try {
      const ctx = await resolveReactionContext(reaction, user);
      if (!ctx) return;
      const { row, member, guild } = ctx;

      if (member.roles.cache.has(row.role_id)) return; // already has it
      await member.roles.add(row.role_id).catch(err => {
        logger.warn(`Reaction role: couldn't add role ${row.role_id} to ${user.tag} in ${guild.name}: ${err.message}`);
        return null;
      });

      if (row.dm_message) {
        const content = fillTemplate(row.dm_message, { user: member.displayName, server: guild.name });
        await member.send(content).catch(() => {
          logger.warn(`Reaction role: couldn't DM ${user.tag} (DMs likely disabled) — role was still granted.`);
        });
      }
    } catch (err) {
      logger.error('messageReactionAdd handler error:', err);
    }
  });

  client.on('messageReactionRemove', async (reaction, user) => {
    try {
      const ctx = await resolveReactionContext(reaction, user);
      if (!ctx) return;
      const { row, member, guild } = ctx;

      if (!member.roles.cache.has(row.role_id)) return; // doesn't have it anyway
      await member.roles.remove(row.role_id).catch(err => {
        logger.warn(`Reaction role: couldn't remove role ${row.role_id} from ${user.tag} in ${guild.name}: ${err.message}`);
      });
    } catch (err) {
      logger.error('messageReactionRemove handler error:', err);
    }
  });

  logger.info('Reaction role handler registered');
}

module.exports = { register };
