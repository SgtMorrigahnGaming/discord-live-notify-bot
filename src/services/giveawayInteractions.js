const { ActionRowBuilder, ButtonBuilder, ButtonStyle } = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');
const { buildOpenGiveawayEmbed, buildEnterButtonRow } = require('../utils/giveawayFormat');

async function handleModal(interaction) {
  if (interaction.customId !== 'giveaway_create_modal') return;

  const draft = db.getGiveawayDraft(interaction.user.id);
  if (!draft) {
    return interaction.reply({ content: "❌ That giveaway builder session expired — run `/giveaway create` again.", ephemeral: true });
  }

  const title = interaction.fields.getTextInputValue('title').trim();
  const prize = interaction.fields.getTextInputValue('prize').trim();
  const durationRaw = interaction.fields.getTextInputValue('duration_hours').trim();
  const description = interaction.fields.getTextInputValue('description').trim();
  const winnerCountRaw = interaction.fields.getTextInputValue('winner_count').trim();

  const durationHours = Number(durationRaw);
  if (!Number.isFinite(durationHours) || durationHours <= 0) {
    return interaction.reply({ content: '❌ Duration (hours) must be a positive number — try again with `/giveaway create`.', ephemeral: true });
  }
  const winnerCount = Number(winnerCountRaw);
  if (!Number.isInteger(winnerCount) || winnerCount < 1) {
    return interaction.reply({ content: '❌ Winner count must be a whole number of at least 1 — try again with `/giveaway create`.', ephemeral: true });
  }

  const channel = await interaction.client.channels.fetch(draft.channel_id).catch(() => null);
  if (!channel) {
    db.deleteGiveawayDraft(interaction.user.id);
    return interaction.reply({ content: "❌ Couldn't find that channel anymore — run `/giveaway create` again.", ephemeral: true });
  }

  const guild = interaction.guild;
  const role = guild.roles.cache.get(draft.entry_role_id);
  if (!role) {
    db.deleteGiveawayDraft(interaction.user.id);
    return interaction.reply({ content: "❌ That entry role no longer exists — run `/giveaway create` again.", ephemeral: true });
  }

  const perms = channel.permissionsFor(guild.members.me);
  if (!perms || !perms.has(['ViewChannel', 'SendMessages'])) {
    db.deleteGiveawayDraft(interaction.user.id);
    return interaction.reply({ content: `❌ I can't send messages in ${channel} — check my permissions there.`, ephemeral: true });
  }

  const endsAt = Math.floor(Date.now() / 1000) + Math.round(durationHours * 3600);

  const giveawayId = db.createGiveaway({
    guildId: draft.guild_id,
    channelId: draft.channel_id,
    title,
    prize,
    description: description || null,
    winnerCount,
    entryRoleId: draft.entry_role_id,
    boosterEnabled: !!draft.booster_bonus_enabled,
    autoRerollEnabled: !!draft.auto_reroll_enabled,
    createdBy: interaction.user.id,
    endsAt,
  });

  const embed = buildOpenGiveawayEmbed({
    title,
    prize,
    description,
    winnerCount,
    entryRoleId: draft.entry_role_id,
    boosterEnabled: !!draft.booster_bonus_enabled,
    endsAt,
    entrantCount: 0,
  });

  let message;
  try {
    message = await channel.send({ embeds: [embed], components: [buildEnterButtonRow(giveawayId, false)] });
  } catch (err) {
    logger.error('Failed to post giveaway:', err);
    db.deleteGiveaway(giveawayId);
    return interaction.reply({ content: `❌ Couldn't post in <#${draft.channel_id}> — check my permissions there.`, ephemeral: true });
  }

  db.setGiveawayMessage(giveawayId, message.id);
  db.deleteGiveawayDraft(interaction.user.id);

  return interaction.reply({ content: `✅ Giveaway posted in <#${draft.channel_id}>, ends <t:${endsAt}:R>. Members with <@&${draft.entry_role_id}> can click **Enter Giveaway** to join.`, ephemeral: true });
}

async function handleClaim(interaction) {
  const winnerId = Number(interaction.customId.split(':')[1]);
  const winner = db.getGiveawayWinner(winnerId);

  if (!winner) {
    return interaction.reply({ content: "❌ Couldn't find that giveaway winner record.", ephemeral: true });
  }
  if (winner.user_id !== interaction.user.id) {
    return interaction.reply({ content: "❌ This isn't your prize to claim.", ephemeral: true });
  }
  if (winner.replaced) {
    return interaction.reply({ content: "⚠️ This winner slot was already rerolled to someone else since it wasn't claimed in time.", ephemeral: true });
  }
  if (winner.claimed) {
    return interaction.reply({ content: '✅ You already claimed this prize.', ephemeral: true });
  }
  const nowTs = Math.floor(Date.now() / 1000);
  if (nowTs > winner.claim_deadline) {
    return interaction.reply({ content: '⏰ The 24-hour claim window has passed.', ephemeral: true });
  }

  const changed = db.markGiveawayWinnerClaimed(winnerId);
  if (!changed) {
    return interaction.reply({ content: '⚠️ Something changed — this prize is no longer claimable by you.', ephemeral: true });
  }

  const giveaway = db.getGiveaway(winner.giveaway_id);
  await interaction.reply({ content: `🎁 Claimed! Reach out to the giveaway host to receive **${giveaway?.prize || 'your prize'}**.`, ephemeral: true });

  // Disable just this winner's button on the announcement message, leaving other winners' buttons untouched
  try {
    const message = interaction.message;
    const newRows = message.components.map(row => {
      const newRow = ActionRowBuilder.from(row);
      newRow.components = row.components.map(c => {
        const btn = ButtonBuilder.from(c);
        if (c.customId === interaction.customId) {
          return btn.setLabel('✅ Claimed').setStyle(ButtonStyle.Secondary).setDisabled(true);
        }
        return btn;
      });
      return newRow;
    });
    await message.edit({ components: newRows }).catch(() => {});
  } catch (err) {
    logger.error('Giveaway: failed to update claim button state:', err);
  }
}

async function handleEnter(interaction) {
  const giveawayId = Number(interaction.customId.split(':')[1]);
  const giveaway = db.getGiveaway(giveawayId);

  if (!giveaway) {
    return interaction.reply({ content: "❌ Couldn't find that giveaway.", ephemeral: true });
  }
  if (giveaway.status !== 'open') {
    return interaction.reply({ content: '⚠️ This giveaway is no longer open.', ephemeral: true });
  }

  const member = interaction.member;
  if (!member || !member.roles.cache.has(giveaway.entry_role_id)) {
    return interaction.reply({ content: `❌ You need <@&${giveaway.entry_role_id}> to enter this giveaway.`, ephemeral: true });
  }

  const alreadyEntered = db.hasGiveawayEntry(giveawayId, interaction.user.id);
  if (alreadyEntered) {
    db.removeGiveawayEntry(giveawayId, interaction.user.id);
    await interaction.reply({ content: '👋 You left the giveaway.', ephemeral: true });
  } else {
    db.addGiveawayEntry(giveawayId, interaction.user.id);
    await interaction.reply({ content: "🎉 You're entered! Good luck.", ephemeral: true });
  }

  const entrantCount = db.getGiveawayEntryCount(giveawayId);

  try {
    const embed = buildOpenGiveawayEmbed({
      title: giveaway.title,
      prize: giveaway.prize,
      description: giveaway.description,
      winnerCount: giveaway.winner_count,
      entryRoleId: giveaway.entry_role_id,
      boosterEnabled: !!giveaway.booster_bonus_enabled,
      endsAt: giveaway.ends_at,
      entrantCount,
    });
    await interaction.message.edit({ embeds: [embed] }).catch(() => {});
  } catch (err) {
    logger.error('Giveaway: failed to refresh entrant count on message:', err);
  }
}

async function handleButton(interaction) {
  if (interaction.customId.startsWith('giveaway_claim:')) {
    return handleClaim(interaction);
  }
  if (interaction.customId.startsWith('giveaway_enter:')) {
    return handleEnter(interaction);
  }
}

module.exports = { handleModal, handleButton };
