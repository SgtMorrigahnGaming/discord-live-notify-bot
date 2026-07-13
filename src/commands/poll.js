const {
  SlashCommandBuilder, PermissionFlagsBits, ChannelType,
  ModalBuilder, TextInputBuilder, TextInputStyle, ActionRowBuilder, EmbedBuilder,
} = require('discord.js');
const db = require('../db');
const { buildPollDescription } = require('../utils/pollFormat');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('poll')
    .setDescription('Create and manage member polls')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('create')
      .setDescription('Start building a new poll (opens a form for the question + first 2 choices)')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post the poll in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addNumberOption(opt => opt.setName('duration_hours').setDescription('How many hours the poll stays open').setMinValue(0.1).setRequired(true))
      .addStringOption(opt => opt.setName('tallies').setDescription('Show live vote counts, or keep them hidden until it closes?').setRequired(true)
        .addChoices(
          { name: 'Hidden until poll closes', value: 'hidden' },
          { name: 'Visible while voting', value: 'visible' },
        )))
    .addSubcommand(sub => sub
      .setName('close')
      .setDescription('Close a poll early and post the results now')
      .addStringOption(opt => opt.setName('message_id').setDescription('The poll message ID (right-click it -> Copy Message ID)').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('results')
      .setDescription('Peek at current results without closing the poll (only visible to you)')
      .addStringOption(opt => opt.setName('message_id').setDescription('The poll message ID').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('List open polls in this server')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'create') {
      const channel = interaction.options.getChannel('channel');
      const durationHours = interaction.options.getNumber('duration_hours');
      const talliesVisible = interaction.options.getString('tallies') === 'visible';

      const perms = channel.permissionsFor(interaction.guild.members.me);
      if (!perms || !perms.has(['ViewChannel', 'SendMessages'])) {
        return interaction.reply({ content: `❌ I can't send messages in ${channel} — check my permissions there.`, ephemeral: true });
      }

      db.savePollDraft(interaction.user.id, interaction.guildId, channel.id, durationHours, talliesVisible);

      const modal = new ModalBuilder().setCustomId('poll_create_modal').setTitle('New Poll');
      const questionInput = new TextInputBuilder().setCustomId('question').setLabel('Poll question').setStyle(TextInputStyle.Paragraph).setMaxLength(200).setRequired(true);
      const choice1Input = new TextInputBuilder().setCustomId('choice1').setLabel('Choice 1').setStyle(TextInputStyle.Short).setMaxLength(80).setRequired(true);
      const choice2Input = new TextInputBuilder().setCustomId('choice2').setLabel('Choice 2').setStyle(TextInputStyle.Short).setMaxLength(80).setRequired(true);

      modal.addComponents(
        new ActionRowBuilder().addComponents(questionInput),
        new ActionRowBuilder().addComponents(choice1Input),
        new ActionRowBuilder().addComponents(choice2Input),
      );

      return interaction.showModal(modal);
    }

    if (sub === 'close') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const poll = db.getPollByMessageId(messageId);
      if (!poll) return interaction.editReply('❌ No poll found with that message ID.');
      if (poll.status === 'closed') return interaction.editReply('⚠️ That poll is already closed.');

      const pollCloser = require('../services/pollCloser');
      await pollCloser.closePollNow(interaction.client, poll.id);
      return interaction.editReply('✅ Poll closed and results posted.');
    }

    if (sub === 'results') {
      const messageId = interaction.options.getString('message_id').trim();
      const poll = db.getPollByMessageId(messageId);
      if (!poll) return interaction.reply({ content: '❌ No poll found with that message ID.', ephemeral: true });

      const counts = db.getVoteCounts(poll.id, poll.choices.length);
      const total = counts.reduce((a, b) => a + b, 0);
      const embed = new EmbedBuilder()
        .setColor(0x5865f2)
        .setTitle(`📊 ${poll.question}`)
        .setDescription(buildPollDescription(poll.choices, counts))
        .setFooter({ text: `${total} total vote${total === 1 ? '' : 's'} so far • ${poll.status === 'open' ? 'still open' : 'closed'}` });
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }

    if (sub === 'list') {
      const polls = db.listOpenPollsForGuild(interaction.guildId);
      if (polls.length === 0) return interaction.reply({ content: 'No open polls right now.', ephemeral: true });
      const lines = polls.map(p => `• **${p.question}** in <#${p.channel_id}> — closes <t:${p.closes_at}:R> — \`${p.message_id}\``);
      const embed = new EmbedBuilder().setColor(0x5865f2).setTitle('Open polls').setDescription(lines.join('\n'));
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }
  },
};
