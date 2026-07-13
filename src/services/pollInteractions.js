const {
  ModalBuilder, TextInputBuilder, TextInputStyle, ActionRowBuilder,
  ButtonBuilder, ButtonStyle, EmbedBuilder,
} = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');
const { buildPollDescription, MAX_CHOICES } = require('../utils/pollFormat');

function expiredReply(interaction) {
  return interaction.reply({ content: "❌ That poll builder session expired — run `/poll create` again.", ephemeral: true });
}

function buildBuilderPreview(draft) {
  const embed = new EmbedBuilder()
    .setColor(0x5865f2)
    .setTitle('📊 Poll builder')
    .setDescription(
      `**Question:** ${draft.question}\n\n` +
      (draft.choices.length ? buildPollDescription(draft.choices, null) : '_No choices yet_') +
      `\n\nCloses in **${draft.duration_hours}h** • Tallies: **${draft.tallies_visible ? 'visible while voting' : 'hidden until close'}**`
    )
    .setFooter({ text: draft.choices.length >= MAX_CHOICES ? `Max ${MAX_CHOICES} choices reached` : 'Add more choices, then post when ready' });

  const row = new ActionRowBuilder().addComponents(
    new ButtonBuilder().setCustomId('poll_addchoice_btn').setLabel('➕ Add Choice').setStyle(ButtonStyle.Secondary).setDisabled(draft.choices.length >= MAX_CHOICES),
    new ButtonBuilder().setCustomId('poll_post_btn').setLabel('✅ Post Poll').setStyle(ButtonStyle.Success).setDisabled(draft.choices.length < 2),
  );

  return { embeds: [embed], components: [row] };
}

function buildOpenPollEmbed({ question, choices, closesAt, talliesVisible, counts }) {
  return new EmbedBuilder()
    .setColor(0x5865f2)
    .setTitle(`📊 ${question}`)
    .setDescription(buildPollDescription(choices, talliesVisible ? counts : null))
    .addFields({ name: 'Closes', value: `<t:${closesAt}:R>` })
    .setFooter({ text: talliesVisible ? 'Tallies update live • Votes are final' : 'Tallies hidden until this poll closes • Votes are final' });
}

function buildVoteButtonRows(pollId, choices) {
  const rows = [];
  for (let i = 0; i < choices.length; i += 5) {
    const row = new ActionRowBuilder();
    for (let j = i; j < Math.min(i + 5, choices.length); j++) {
      row.addComponents(
        new ButtonBuilder()
          .setCustomId(`poll_vote:${pollId}:${j}`)
          .setLabel(choices[j].slice(0, 80))
          .setStyle(ButtonStyle.Primary)
      );
    }
    rows.push(row);
  }
  return rows;
}

async function handleModal(interaction) {
  if (interaction.customId === 'poll_create_modal') {
    const existingDraft = db.getPollDraft(interaction.user.id);
    if (!existingDraft) return expiredReply(interaction);

    const question = interaction.fields.getTextInputValue('question').trim();
    const choice1 = interaction.fields.getTextInputValue('choice1').trim();
    const choice2 = interaction.fields.getTextInputValue('choice2').trim();

    db.setPollDraftQuestionAndChoices(interaction.user.id, question, [choice1, choice2]);
    const draft = db.getPollDraft(interaction.user.id);

    return interaction.reply({ ...buildBuilderPreview(draft), ephemeral: true });
  }

  if (interaction.customId === 'poll_addchoice_modal') {
    const draft = db.getPollDraft(interaction.user.id);
    if (!draft) return expiredReply(interaction);
    if (draft.choices.length >= MAX_CHOICES) {
      return interaction.reply({ content: `❌ Polls are capped at ${MAX_CHOICES} choices.`, ephemeral: true });
    }

    const choiceText = interaction.fields.getTextInputValue('choice').trim();
    db.addPollDraftChoice(interaction.user.id, choiceText);
    const updated = db.getPollDraft(interaction.user.id);

    if (interaction.isFromMessage()) {
      return interaction.update(buildBuilderPreview(updated));
    }
    return interaction.reply({ ...buildBuilderPreview(updated), ephemeral: true });
  }
}

async function handleButton(interaction) {
  if (interaction.customId === 'poll_addchoice_btn') {
    const draft = db.getPollDraft(interaction.user.id);
    if (!draft) return expiredReply(interaction);
    if (draft.choices.length >= MAX_CHOICES) {
      return interaction.reply({ content: `❌ Polls are capped at ${MAX_CHOICES} choices.`, ephemeral: true });
    }

    const nextNum = draft.choices.length + 1;
    const modal = new ModalBuilder().setCustomId('poll_addchoice_modal').setTitle(`Choice ${nextNum}`);
    const input = new TextInputBuilder().setCustomId('choice').setLabel(`Choice ${nextNum}`).setStyle(TextInputStyle.Short).setMaxLength(80).setRequired(true);
    modal.addComponents(new ActionRowBuilder().addComponents(input));
    return interaction.showModal(modal);
  }

  if (interaction.customId === 'poll_post_btn') {
    const draft = db.getPollDraft(interaction.user.id);
    if (!draft) return expiredReply(interaction);
    if (draft.choices.length < 2) {
      return interaction.reply({ content: '❌ Add at least 2 choices before posting.', ephemeral: true });
    }

    const channel = await interaction.client.channels.fetch(draft.channel_id).catch(() => null);
    if (!channel) {
      return interaction.update({ content: "❌ Couldn't find that channel anymore — run `/poll create` again.", embeds: [], components: [] });
    }

    const closesAt = Math.floor(Date.now() / 1000) + Math.round(draft.duration_hours * 3600);
    const pollId = db.createPoll({
      guildId: draft.guild_id,
      channelId: draft.channel_id,
      question: draft.question,
      choices: draft.choices,
      talliesVisible: !!draft.tallies_visible,
      createdBy: interaction.user.id,
      closesAt,
    });

    const embed = buildOpenPollEmbed({
      question: draft.question,
      choices: draft.choices,
      closesAt,
      talliesVisible: !!draft.tallies_visible,
      counts: draft.tallies_visible ? new Array(draft.choices.length).fill(0) : null,
    });
    const rows = buildVoteButtonRows(pollId, draft.choices);

    let message;
    try {
      message = await channel.send({ embeds: [embed], components: rows });
    } catch (err) {
      logger.error('Failed to post poll:', err);
      return interaction.update({ content: `❌ Couldn't post in <#${draft.channel_id}> — check my permissions there.`, embeds: [], components: [] });
    }

    db.setPollMessage(pollId, message.id);
    db.deletePollDraft(interaction.user.id);

    return interaction.update({ content: `✅ Poll posted in <#${draft.channel_id}>, closes <t:${closesAt}:R>.`, embeds: [], components: [] });
  }

  if (interaction.customId.startsWith('poll_vote:')) {
    const [, pollIdRaw, choiceIdxRaw] = interaction.customId.split(':');
    const pollId = Number(pollIdRaw);
    const choiceIndex = Number(choiceIdxRaw);
    const poll = db.getPoll(pollId);

    if (!poll || poll.status === 'closed') {
      return interaction.reply({ content: '⚠️ This poll has closed.', ephemeral: true });
    }

    const recorded = db.castVote(pollId, interaction.user.id, choiceIndex);
    if (!recorded) {
      return interaction.reply({ content: "⚠️ You've already voted on this poll — votes are final and can't be changed.", ephemeral: true });
    }

    await interaction.reply({ content: `✅ Your vote for **${poll.choices[choiceIndex]}** has been recorded.`, ephemeral: true });

    if (poll.tallies_visible) {
      const counts = db.getVoteCounts(pollId, poll.choices.length);
      const embed = buildOpenPollEmbed({ question: poll.question, choices: poll.choices, closesAt: poll.closes_at, talliesVisible: true, counts });
      const message = await interaction.channel.messages.fetch(poll.message_id).catch(() => null);
      if (message) await message.edit({ embeds: [embed] }).catch(() => {});
    }
  }
}

module.exports = { handleButton, handleModal, buildOpenPollEmbed, buildVoteButtonRows };
