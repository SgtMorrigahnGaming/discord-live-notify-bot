const { EmbedBuilder } = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');
const { buildEntrantPool, pickWinners, buildClosedGiveawayEmbed, CLAIM_WINDOW_MS } = require('../utils/giveawayFormat');

let running = false;

async function dmWinner(client, giveaway, winnerId, userId) {
  try {
    const user = await client.users.fetch(userId);
    const embed = new EmbedBuilder()
      .setColor(0xf2b705)
      .setTitle(`🎉 You won: ${giveaway.title}`)
      .setDescription(
        `**Prize:** ${giveaway.prize}\n\n` +
        `You have **24 hours** to claim this in the server, or ` +
        (giveaway.auto_reroll_enabled ? 'a new winner will be rerolled.' : 'the prize may go unclaimed.') +
        `\n\nHead back to the giveaway announcement in the server and use the **Claim Prize** button there.`
      );
    await user.send({ embeds: [embed] }).catch(() => {
      logger.warn(`Giveaway: couldn't DM winner ${userId} for giveaway ${giveaway.id} (DMs likely disabled).`);
    });
  } catch (err) {
    logger.error(`Giveaway: failed to DM winner ${userId}:`, err);
  }
}

function buildClaimButtonRow(winnerId) {
  const { ActionRowBuilder, ButtonBuilder, ButtonStyle } = require('discord.js');
  return new ActionRowBuilder().addComponents(
    new ButtonBuilder().setCustomId(`giveaway_claim:${winnerId}`).setLabel('🎁 Claim Prize').setStyle(ButtonStyle.Success)
  );
}

async function closeGiveawayNow(client, giveawayId) {
  const giveaway = db.getGiveaway(giveawayId);
  if (!giveaway || giveaway.status === 'closed') return;

  db.closeGiveaway(giveawayId);

  let entrantCount = 0;
  let winnerIds = [];
  try {
    const guild = await client.guilds.fetch(giveaway.guild_id);
    const tickets = await buildEntrantPool(guild, giveaway.entry_role_id, !!giveaway.booster_bonus_enabled);
    entrantCount = new Set(tickets).size;
    winnerIds = pickWinners(tickets, giveaway.winner_count);
    db.setGiveawayEntrantCount(giveawayId, entrantCount);
  } catch (err) {
    logger.error(`Giveaway: failed to build entrant pool for giveaway ${giveawayId}:`, err);
  }

  const claimDeadline = Math.floor((Date.now() + CLAIM_WINDOW_MS) / 1000);
  const winnerRows = winnerIds.map(userId => {
    const winnerId = db.addGiveawayWinner(giveawayId, userId, claimDeadline, false);
    return db.getGiveawayWinner(winnerId);
  });

  try {
    const channel = await client.channels.fetch(giveaway.channel_id);
    const closedEmbed = buildClosedGiveawayEmbed({
      title: giveaway.title,
      prize: giveaway.prize,
      description: giveaway.description,
      winners: winnerRows,
      entrantCount,
    });

    if (giveaway.message_id) {
      const message = await channel.messages.fetch(giveaway.message_id).catch(() => null);
      if (message) await message.edit({ embeds: [closedEmbed], components: [] }).catch(() => {});
    }

    if (winnerRows.length === 0) {
      await channel.send({ content: `🎉 **${giveaway.title}** has ended — no eligible entrants, so no winner was picked.` });
    } else {
      const rows = winnerRows.map(buildClaimButtonRow);
      await channel.send({
        content: `🎉 **${giveaway.title}** has ended!\nWinner${winnerRows.length === 1 ? '' : 's'}: ${winnerRows.map(w => `<@${w.user_id}>`).join(', ')}\nCheck your DMs, then hit **Claim Prize** below within 24h.`,
        components: rows.slice(0, 5),
      });
    }
  } catch (err) {
    logger.error(`Giveaway: failed to announce results for giveaway ${giveawayId}:`, err);
  }

  for (const w of winnerRows) {
    await dmWinner(client, giveaway, w.id, w.user_id);
  }
}

async function rerollWinner(client, oldWinner) {
  const giveaway = db.getGiveaway(oldWinner.giveaway_id);
  if (!giveaway) return;

  db.markGiveawayWinnerReplaced(oldWinner.id);

  try {
    const guild = await client.guilds.fetch(giveaway.guild_id);
    const tickets = await buildEntrantPool(guild, giveaway.entry_role_id, !!giveaway.booster_bonus_enabled);
    const existingWinnerIds = db.getGiveawayWinners(giveaway.id).map(w => w.user_id);
    const [newWinnerId] = pickWinners(tickets, 1, existingWinnerIds);

    const channel = await client.channels.fetch(giveaway.channel_id).catch(() => null);

    if (!newWinnerId) {
      if (channel) {
        await channel.send({ content: `⚠️ **${giveaway.title}**: <@${oldWinner.user_id}> didn't claim in time, but there's no one left to reroll to — that prize slot goes unclaimed.` }).catch(() => {});
      }
      return;
    }

    const claimDeadline = Math.floor((Date.now() + CLAIM_WINDOW_MS) / 1000);
    const newWinnerRowId = db.addGiveawayWinner(giveaway.id, newWinnerId, claimDeadline, true);
    const newWinner = db.getGiveawayWinner(newWinnerRowId);

    if (channel) {
      await channel.send({
        content: `🔁 **${giveaway.title}**: <@${oldWinner.user_id}> didn't claim in time, so the prize has been rerolled to <@${newWinnerId}>! You have 24h to claim.`,
        components: [buildClaimButtonRow(newWinner.id)],
      }).catch(() => {});
    }

    await dmWinner(client, giveaway, newWinner.id, newWinnerId);
  } catch (err) {
    logger.error(`Giveaway: failed to reroll winner slot ${oldWinner.id}:`, err);
  }
}

async function checkOnce(client) {
  if (running) return;
  running = true;
  try {
    const nowTs = Math.floor(Date.now() / 1000);

    const dueGiveaways = db.listOpenGiveawaysPastEnd(nowTs);
    for (const giveawayId of dueGiveaways) {
      await closeGiveawayNow(client, giveawayId);
    }

    const rerollable = db.listRerollableExpiredWinners(nowTs);
    for (const winner of rerollable) {
      await rerollWinner(client, winner);
    }

    const finalizable = db.listFinalizableExpiredWinners(nowTs);
    for (const winner of finalizable) {
      db.markGiveawayWinnerUnclaimedFinal(winner.id);
    }
  } catch (err) {
    logger.error('Giveaway closer error:', err);
  } finally {
    running = false;
  }
}

function start(client) {
  logger.info('Starting giveaway auto-closer (checks every 60s)');
  checkOnce(client);
  setInterval(() => checkOnce(client), 60_000);
}

module.exports = { start, closeGiveawayNow, buildClaimButtonRow };
