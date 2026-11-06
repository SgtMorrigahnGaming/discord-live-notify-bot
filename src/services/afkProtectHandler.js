const { AuditLogEvent } = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');

// Discord's AFK move is a guild-level setting enforced server-side — a bot has no way to
// block it before it happens. What this module does instead is detect the move the instant
// it fires (via voiceStateUpdate) and move the member straight back to where they came from,
// so in practice it looks like the channel/member was never touched.

// Mirrors the audit-log lookup pattern from modLogHandler: MEMBER_MOVE entries only exist
// when a moderator deliberately moved someone else, so if we find one that lines up with this
// event, a human did this on purpose and we should leave it alone.
const AUDIT_LOG_RETRY_DELAY_MS = 1500;
const AUDIT_LOG_MAX_AGE_MS = 10_000;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function findMoveAuditEntry(guild, fromChannelId) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const logs = await guild.fetchAuditLogs({ type: AuditLogEvent.MemberMove, limit: 5 });
      // MEMBER_MOVE entries have no target member (Discord can bulk-move several people at
      // once) — extra.channel is the channel they were moved OUT of, which is what we match on.
      const entry = logs.entries.find(
        (e) => Date.now() - e.createdTimestamp < AUDIT_LOG_MAX_AGE_MS && e.extra?.channel?.id === fromChannelId
      );
      if (entry) return entry;
    } catch (err) {
      // Missing View Audit Log permission or a transient API error — fail open and treat
      // the move as unattended rather than silently never protecting anyone.
      logger.warn(`AFK protect: couldn't fetch audit logs in ${guild.name}: ${err.message}`);
      return null;
    }
    if (attempt === 0) await sleep(AUDIT_LOG_RETRY_DELAY_MS);
  }
  return null;
}

function register(client) {
  client.on('voiceStateUpdate', async (oldState, newState) => {
    try {
      const guild = newState.guild;
      const afkChannelId = guild.afkChannelId;
      if (!afkChannelId) return; // server has no AFK channel configured
      if (newState.channelId !== afkChannelId) return; // not a move into the AFK channel
      if (oldState.channelId === afkChannelId) return; // was already in the AFK channel — nothing to revert to
      if (!oldState.channelId) return; // no prior channel to send them back to

      const member = newState.member;
      if (!member || member.user.bot) return;

      const protectedByChannel = db.isAfkProtectedChannel(guild.id, oldState.channelId);
      const protectedByUser = db.isAfkProtectedUser(guild.id, member.id);
      if (!protectedByChannel && !protectedByUser) return;

      // MEMBER_MOVE audit entries only fire when a moderator manually moves someone else's
      // voice state. Discord's own idle-timeout AFK move produces no audit entry at all, and
      // neither does a member walking into the AFK channel themselves — both cases fall through
      // here and get reverted, which matches "protect them from ending up parked in AFK."
      const moveEntry = await findMoveAuditEntry(guild, oldState.channelId);
      if (moveEntry && moveEntry.executor?.id !== client.user.id) {
        logger.info(`AFK protect: skipping revert for ${member.user.tag} in ${guild.name} — moved deliberately by ${moveEntry.executor?.tag || 'a moderator'}`);
        return;
      }

      const targetChannel = guild.channels.cache.get(oldState.channelId);
      if (!targetChannel) return; // the channel they came from no longer exists

      await member.voice.setChannel(targetChannel).catch((err) => {
        logger.warn(`AFK protect: couldn't move ${member.user.tag} back to #${targetChannel.name} in ${guild.name}: ${err.message}`);
      });
      logger.info(`AFK protect: moved ${member.user.tag} back to #${targetChannel.name} in ${guild.name} (reverted AFK move)`);
    } catch (err) {
      logger.error('AFK protect: voiceStateUpdate handler error:', err);
    }
  });

  logger.info('AFK protect handler registered');
}

module.exports = { register };
