const { EmbedBuilder, AuditLogEvent } = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');

// Audit log entries can take a moment to appear after the triggering event fires.
const AUDIT_LOG_RETRY_DELAY_MS = 1500;
const AUDIT_LOG_MAX_AGE_MS = 10_000; // ignore stale entries that predate this event

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function sendToCategory(client, guildId, channelIdField, embed) {
  const config = db.getModlogConfig(guildId);
  const channelId = config?.[channelIdField];
  if (!channelId) return; // category not routed to a channel — nothing to do
  const channel = await client.channels.fetch(channelId).catch(() => null);
  if (!channel) {
    logger.warn(`ModLog: configured channel ${channelId} (${channelIdField}) not found in guild ${guildId}`);
    return;
  }
  await channel.send({ embeds: [embed] }).catch((err) => {
    logger.error(`ModLog: failed to post to ${channelIdField} channel in guild ${guildId}:`, err);
  });
}

// Looks up the most recent matching audit log entry for a target, retrying once since
// Discord's audit log can lag slightly behind the event that triggered it.
async function findAuditLogEntry(guild, type, targetId) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const logs = await guild.fetchAuditLogs({ type, limit: 5 });
      const entry = logs.entries.find(
        (e) => e.target?.id === targetId && Date.now() - e.createdTimestamp < AUDIT_LOG_MAX_AGE_MS
      );
      if (entry) return entry;
    } catch (err) {
      logger.warn(`ModLog: couldn't fetch audit logs in ${guild.name} (missing View Audit Log permission?):`, err.message);
      return null;
    }
    if (attempt === 0) await sleep(AUDIT_LOG_RETRY_DELAY_MS);
  }
  return null;
}

function register(client) {
  // ---- Bans ----
  client.on('guildBanAdd', async (ban) => {
    try {
      const entry = await findAuditLogEntry(ban.guild, AuditLogEvent.MemberBanAdd, ban.user.id);
      const embed = new EmbedBuilder()
        .setColor(0xe74c3c)
        .setTitle('🔨 Member banned')
        .setDescription(`${ban.user.tag} (${ban.user.id})`)
        .addFields(
          { name: 'Moderator', value: entry?.executor ? `${entry.executor.tag}` : 'Unknown' },
          { name: 'Reason', value: entry?.reason || ban.reason || 'No reason provided' }
        )
        .setTimestamp();
      await sendToCategory(client, ban.guild.id, 'ban_channel_id', embed);
    } catch (err) {
      logger.error('ModLog: guildBanAdd handler error:', err);
    }
  });

  // ---- Kicks ---- (guildMemberRemove fires for kicks AND voluntary leaves — audit log disambiguates)
  client.on('guildMemberRemove', async (member) => {
    try {
      const entry = await findAuditLogEntry(member.guild, AuditLogEvent.MemberKick, member.id);
      if (!entry) return; // no matching kick entry — this was a voluntary leave, not our concern

      const embed = new EmbedBuilder()
        .setColor(0xe67e22)
        .setTitle('👢 Member kicked')
        .setDescription(`${member.user.tag} (${member.id})`)
        .addFields(
          { name: 'Moderator', value: entry.executor ? `${entry.executor.tag}` : 'Unknown' },
          { name: 'Reason', value: entry.reason || 'No reason provided' }
        )
        .setTimestamp();
      await sendToCategory(client, member.guild.id, 'kick_channel_id', embed);
    } catch (err) {
      logger.error('ModLog: guildMemberRemove handler error:', err);
    }
  });

  // ---- Timeouts + role removals ----
  client.on('guildMemberUpdate', async (oldMember, newMember) => {
    try {
      const oldTimeout = oldMember.communicationDisabledUntilTimestamp;
      const newTimeout = newMember.communicationDisabledUntilTimestamp;
      if (newTimeout && newTimeout !== oldTimeout && newTimeout > Date.now()) {
        const entry = await findAuditLogEntry(newMember.guild, AuditLogEvent.MemberUpdate, newMember.id);
        const embed = new EmbedBuilder()
          .setColor(0xf1c40f)
          .setTitle('🔇 Member timed out')
          .setDescription(`${newMember.user.tag} (${newMember.id})`)
          .addFields(
            { name: 'Moderator', value: entry?.executor ? `${entry.executor.tag}` : 'Unknown' },
            { name: 'Until', value: `<t:${Math.floor(newTimeout / 1000)}:F>` },
            { name: 'Reason', value: entry?.reason || 'No reason provided' }
          )
          .setTimestamp();
        await sendToCategory(client, newMember.guild.id, 'timeout_channel_id', embed);
        return;
      }

      const removedRoles = oldMember.roles.cache.filter((r) => !newMember.roles.cache.has(r.id));
      if (removedRoles.size > 0) {
        const entry = await findAuditLogEntry(newMember.guild, AuditLogEvent.MemberRoleUpdate, newMember.id);
        const embed = new EmbedBuilder()
          .setColor(0x95a5a6)
          .setTitle('🏷️ Role removed')
          .setDescription(`${newMember.user.tag} (${newMember.id})`)
          .addFields(
            { name: 'Roles removed', value: removedRoles.map((r) => r.name).join(', ') },
            { name: 'Moderator', value: entry?.executor ? `${entry.executor.tag}` : 'Unknown' }
          )
          .setTimestamp();
        await sendToCategory(client, newMember.guild.id, 'roleremove_channel_id', embed);
      }
    } catch (err) {
      logger.error('ModLog: guildMemberUpdate handler error:', err);
    }
  });

  logger.info('Mod log handler registered');
}

module.exports = { register, sendToCategory };
