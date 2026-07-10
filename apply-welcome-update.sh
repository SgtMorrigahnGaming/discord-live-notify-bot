#!/bin/bash
set -e
echo "Setting up welcome system + updating reaction roles..."
mkdir -p src/utils src/commands src/services
cat > src/utils/welcomeCard.js << 'EOF_MARKER_src_utils_welcomeCard_js'
const path = require('path');
const { createCanvas, loadImage, GlobalFonts } = require('@napi-rs/canvas');
const logger = require('./logger');

// Bundle our own font rather than relying on the OS having one installed — the Docker base
// image (node:22-slim) ships with no fonts at all, which would otherwise render blank text.
const FONT_DIR = path.resolve(__dirname, '../../node_modules/@fontsource/inter/files');
let fontsReady = false;
function ensureFonts() {
  if (fontsReady) return;
  try {
    GlobalFonts.registerFromPath(path.join(FONT_DIR, 'inter-latin-700-normal.woff2'), 'Inter-Bold');
    GlobalFonts.registerFromPath(path.join(FONT_DIR, 'inter-latin-600-normal.woff2'), 'Inter-Semibold');
    GlobalFonts.registerFromPath(path.join(FONT_DIR, 'inter-latin-400-normal.woff2'), 'Inter-Regular');
    fontsReady = true;
  } catch (err) {
    logger.error('Failed to register welcome card fonts:', err);
  }
}

function roundedRectPath(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** Shrinks font size until the text fits within maxWidth, down to a minimum size. */
function fitFontSize(ctx, text, family, startSize, minSize, maxWidth) {
  let size = startSize;
  while (size > minSize) {
    ctx.font = `700 ${size}px ${family}`;
    if (ctx.measureText(text).width <= maxWidth) break;
    size -= 2;
  }
  return size;
}

async function generateWelcomeCard({ avatarUrl, username, guildName, memberCount }) {
  ensureFonts();

  const W = 900, H = 300;
  const canvas = createCanvas(W, H);
  const ctx = canvas.getContext('2d');

  // Card background with rounded corners
  roundedRectPath(ctx, 0, 0, W, H, 24);
  ctx.clip();

  const bgGrad = ctx.createLinearGradient(0, 0, W, H);
  bgGrad.addColorStop(0, '#14151b');
  bgGrad.addColorStop(1, '#2a1a4a');
  ctx.fillStyle = bgGrad;
  ctx.fillRect(0, 0, W, H);

  // Soft decorative glow, top-right — purely cosmetic, keeps it from feeling too flat/corporate
  const glow = ctx.createRadialGradient(W - 80, 40, 0, W - 80, 40, 220);
  glow.addColorStop(0, 'rgba(145, 70, 255, 0.35)');
  glow.addColorStop(1, 'rgba(145, 70, 255, 0)');
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, W, H);

  // Avatar
  const avatarSize = 176;
  const avatarX = 62;
  const avatarY = (H - avatarSize) / 2;

  let avatarImg = null;
  try {
    if (avatarUrl) {
      const res = await fetch(avatarUrl);
      if (res.ok) {
        const buf = Buffer.from(await res.arrayBuffer());
        avatarImg = await loadImage(buf);
      }
    }
  } catch (err) {
    logger.warn('Welcome card: failed to load avatar, using fallback:', err.message);
  }

  ctx.save();
  ctx.beginPath();
  ctx.arc(avatarX + avatarSize / 2, avatarY + avatarSize / 2, avatarSize / 2, 0, Math.PI * 2);
  ctx.closePath();
  ctx.clip();
  if (avatarImg) {
    ctx.drawImage(avatarImg, avatarX, avatarY, avatarSize, avatarSize);
  } else {
    ctx.fillStyle = '#5865f2';
    ctx.fillRect(avatarX, avatarY, avatarSize, avatarSize);
  }
  ctx.restore();

  // Ring around avatar
  ctx.beginPath();
  ctx.arc(avatarX + avatarSize / 2, avatarY + avatarSize / 2, avatarSize / 2 + 3, 0, Math.PI * 2);
  ctx.lineWidth = 5;
  ctx.strokeStyle = '#9146ff';
  ctx.stroke();

  // Text block
  const textX = avatarX + avatarSize + 44;
  const maxTextWidth = W - textX - 40;

  ctx.fillStyle = '#9146ff';
  ctx.font = '700 16px Inter-Semibold';
  ctx.textBaseline = 'alphabetic';
  ctx.fillText('W E L C O M E', textX, 108);

  const nameSize = fitFontSize(ctx, username, 'Inter-Bold', 46, 26, maxTextWidth);
  ctx.fillStyle = '#ffffff';
  ctx.font = `700 ${nameSize}px Inter-Bold`;
  ctx.fillText(username, textX, 108 + nameSize + 6);

  ctx.fillStyle = '#c3c5d0';
  ctx.font = '400 22px Inter-Regular';
  ctx.fillText(`to ${guildName}`, textX, 108 + nameSize + 44);

  if (memberCount) {
    ctx.fillStyle = '#8a8d9a';
    ctx.font = '400 16px Inter-Regular';
    ctx.fillText(`Member #${memberCount}`, textX, H - 34);
  }

  return canvas.toBuffer('image/png');
}

module.exports = { generateWelcomeCard };
EOF_MARKER_src_utils_welcomeCard_js

cat > src/commands/welcome.js << 'EOF_MARKER_src_commands_welcome_js'
const { SlashCommandBuilder, PermissionFlagsBits, ChannelType, AttachmentBuilder } = require('discord.js');
const db = require('../db');
const { generateWelcomeCard } = require('../utils/welcomeCard');

function fillTemplate(template, vars) {
  if (!template) return null;
  let out = template;
  for (const [key, val] of Object.entries(vars)) {
    out = out.replaceAll(`{${key}}`, val ?? '');
  }
  return out;
}

module.exports = {
  data: new SlashCommandBuilder()
    .setName('welcome')
    .setDescription('Configure the welcome card + DM new members get when they join')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('setup')
      .setDescription('Turn on welcome messages')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post the welcome card in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('dm_message').setDescription('Optional DM to send too. Use {user} {server}').setRequired(false)))
    .addSubcommand(sub => sub
      .setName('test')
      .setDescription('Preview the welcome card + DM using your own account, without posting publicly'))
    .addSubcommand(sub => sub
      .setName('disable')
      .setDescription('Turn off welcome messages (keeps your settings for later)'))
    .addSubcommand(sub => sub
      .setName('enable')
      .setDescription('Turn welcome messages back on using previously saved settings')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'setup') {
      const channel = interaction.options.getChannel('channel');
      const dmMessage = interaction.options.getString('dm_message');
      db.setWelcomeConfig(interaction.guildId, channel.id, dmMessage || null);
      return interaction.reply({
        content: `✅ New members will now get a welcome card in ${channel}` +
          (dmMessage ? ' plus a DM.' : '. No DM configured — add one anytime by running \`/welcome setup\` again.') +
          `\n\nTry \`/welcome test\` to preview it before anyone else sees it.`,
        ephemeral: true,
      });
    }

    if (sub === 'test') {
      await interaction.deferReply({ ephemeral: true });
      const config = db.getWelcomeConfig(interaction.guildId);
      if (!config) {
        return interaction.editReply('⚠️ Welcome messages haven\'t been set up yet — run `/welcome setup` first.');
      }

      const member = interaction.member;
      const buffer = await generateWelcomeCard({
        avatarUrl: member.displayAvatarURL({ extension: 'png', size: 256 }),
        username: member.user.username,
        guildName: interaction.guild.name,
        memberCount: interaction.guild.memberCount,
      });
      const attachment = new AttachmentBuilder(buffer, { name: 'welcome-preview.png' });

      const dmPreview = config.dm_message
        ? `\n\n**DM preview:**\n> ${fillTemplate(config.dm_message, { user: member.displayName, server: interaction.guild.name })}`
        : '\n\n*(No DM configured)*';

      return interaction.editReply({
        content: `This is what new members will see in <#${config.channel_id}>:${dmPreview}`,
        files: [attachment],
      });
    }

    if (sub === 'disable') {
      const changes = db.setWelcomeEnabled(interaction.guildId, false);
      if (changes === 0) {
        return interaction.reply({ content: '⚠️ Welcome messages were never set up — nothing to disable.', ephemeral: true });
      }
      return interaction.reply({ content: '🔕 Welcome messages turned off. Your channel/DM settings are kept — run `/welcome enable` to turn back on.', ephemeral: true });
    }

    if (sub === 'enable') {
      const config = db.getWelcomeConfig(interaction.guildId);
      if (!config) {
        return interaction.reply({ content: '⚠️ No previous settings found — run `/welcome setup` instead.', ephemeral: true });
      }
      db.setWelcomeEnabled(interaction.guildId, true);
      return interaction.reply({ content: `🔔 Welcome messages turned back on, posting in <#${config.channel_id}>.`, ephemeral: true });
    }
  },
};
EOF_MARKER_src_commands_welcome_js

cat > src/services/welcomeHandler.js << 'EOF_MARKER_src_services_welcomeHandler_js'
const { AttachmentBuilder } = require('discord.js');
const db = require('../db');
const { generateWelcomeCard } = require('../utils/welcomeCard');
const logger = require('../utils/logger');

function fillTemplate(template, vars) {
  if (!template) return null;
  let out = template;
  for (const [key, val] of Object.entries(vars)) {
    out = out.replaceAll(`{${key}}`, val ?? '');
  }
  return out;
}

function register(client) {
  client.on('guildMemberAdd', async (member) => {
    try {
      const config = db.getWelcomeConfig(member.guild.id);
      if (!config || !config.enabled) return;

      const channel = await member.guild.channels.fetch(config.channel_id).catch(() => null);
      if (!channel) {
        logger.warn(`Welcome: configured channel ${config.channel_id} not found in guild ${member.guild.name}`);
      } else {
        try {
          const buffer = await generateWelcomeCard({
            avatarUrl: member.displayAvatarURL({ extension: 'png', size: 256 }),
            username: member.user.username,
            guildName: member.guild.name,
            memberCount: member.guild.memberCount,
          });
          const attachment = new AttachmentBuilder(buffer, { name: 'welcome.png' });
          await channel.send({ content: `Welcome ${member}! 🎉`, files: [attachment] });
        } catch (err) {
          logger.error(`Welcome: failed to post card in ${member.guild.name}:`, err);
        }
      }

      if (config.dm_message) {
        const content = fillTemplate(config.dm_message, { user: member.displayName, server: member.guild.name });
        await member.send(content).catch(() => {
          logger.warn(`Welcome: couldn't DM ${member.user.tag} (DMs likely disabled).`);
        });
      }
    } catch (err) {
      logger.error('guildMemberAdd handler error:', err);
    }
  });

  logger.info('Welcome handler registered');
}

module.exports = { register };
EOF_MARKER_src_services_welcomeHandler_js

cat > src/commands/reactionroles.js << 'EOF_MARKER_src_commands_reactionroles_js'
const { SlashCommandBuilder, PermissionFlagsBits, EmbedBuilder, ChannelType } = require('discord.js');
const db = require('../db');
const emojiUtil = require('../utils/emoji');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('reactionroles')
    .setDescription('Set up self-serve roles via message reactions')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('create-panel')
      .setDescription('Post a new panel message that you can attach reaction roles to')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post the panel in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('title').setDescription('Panel title').setRequired(true))
      .addStringOption(opt => opt.setName('description').setDescription('Panel description').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('add')
      .setDescription('Attach an emoji-role pair to an existing panel message')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID (right-click it -> Copy Message ID)').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel the panel message is in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('emoji').setDescription('Emoji to react with (pick from the emoji picker)').setRequired(true))
      .addRoleOption(opt => opt.setName('role').setDescription('Role to grant when someone reacts').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('remove')
      .setDescription('Remove an emoji-role pair from a panel')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel the panel message is in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('emoji').setDescription('Emoji to remove').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('List emoji-role pairs on a panel')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID').setRequired(true))),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'create-panel') {
      const channel = interaction.options.getChannel('channel');
      const title = interaction.options.getString('title');
      const description = interaction.options.getString('description');

      const embed = new EmbedBuilder().setColor(0x5865f2).setTitle(title).setDescription(description);
      const message = await channel.send({ embeds: [embed] }).catch(() => null);
      if (!message) {
        return interaction.reply({ content: `❌ Couldn't post in ${channel} — check I have permission to send messages there.`, ephemeral: true });
      }

      return interaction.reply({
        content: `✅ Panel posted in ${channel}.\nMessage ID: \`${message.id}\`\n\nNow use \`/reactionroles add\` with that message ID to attach emoji-role pairs to it.`,
        ephemeral: true,
      });
    }

    if (sub === 'add') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const channel = interaction.options.getChannel('channel');
      const rawEmoji = interaction.options.getString('emoji');
      const role = interaction.options.getRole('role');

      const parsedEmoji = emojiUtil.parseEmojiInput(rawEmoji);
      if (!parsedEmoji) {
        return interaction.editReply(`❌ Couldn't understand \`${rawEmoji}\` as an emoji. Pick one from Discord's emoji picker rather than typing a shortcode.`);
      }

      if (role.managed || role.id === interaction.guild.id) {
        return interaction.editReply(`❌ Can't use that role — it's managed by an integration or is the default @everyone role.`);
      }
      if (interaction.guild.members.me.roles.highest.position <= role.position) {
        return interaction.editReply(`❌ I can't assign **${role.name}** — it's positioned above my own highest role. Move my role above it in Server Settings → Roles.`);
      }

      const message = await channel.messages.fetch(messageId).catch(() => null);
      if (!message) {
        return interaction.editReply(`❌ Couldn't find a message with ID \`${messageId}\` in ${channel}.`);
      }

      try {
        await message.react(emojiUtil.toReactString(parsedEmoji));
      } catch (err) {
        return interaction.editReply(`❌ Couldn't react with that emoji: ${err.message}. If it's a custom emoji, make sure it's from this server (or one I'm also in).`);
      }

      db.addReactionRole(interaction.guildId, channel.id, messageId, parsedEmoji.id, parsedEmoji.name, role.id, null);

      return interaction.editReply(`✅ ${emojiUtil.displayEmoji(parsedEmoji)} on that panel now grants **${role.name}**.`);
    }

    if (sub === 'remove') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const channel = interaction.options.getChannel('channel');
      const rawEmoji = interaction.options.getString('emoji');

      const parsedEmoji = emojiUtil.parseEmojiInput(rawEmoji);
      if (!parsedEmoji) {
        return interaction.editReply(`❌ Couldn't understand \`${rawEmoji}\` as an emoji.`);
      }

      const changes = db.removeReactionRole(messageId, parsedEmoji.id, parsedEmoji.name);
      if (changes === 0) {
        return interaction.editReply(`⚠️ That emoji wasn't attached to that message.`);
      }

      const message = await channel.messages.fetch(messageId).catch(() => null);
      if (message) {
        const reaction = message.reactions.cache.find(r =>
          parsedEmoji.id ? r.emoji.id === parsedEmoji.id : r.emoji.name === parsedEmoji.name
        );
        if (reaction) await reaction.users.remove(interaction.client.user.id).catch(() => {});
      }

      return interaction.editReply(`🗑️ Removed ${emojiUtil.displayEmoji(parsedEmoji)} from that panel.`);
    }

    if (sub === 'list') {
      const messageId = interaction.options.getString('message_id').trim();
      const rows = db.listReactionRolesForMessage(messageId);
      if (rows.length === 0) {
        return interaction.reply({ content: 'No emoji-role pairs are attached to that message yet.', ephemeral: true });
      }
      const embed = new EmbedBuilder()
        .setColor(0x5865f2)
        .setTitle('Reaction roles on this panel')
        .setDescription(rows.map(r => {
          const emoji = emojiUtil.displayEmoji({ id: r.emoji_id, name: r.emoji_name });
          return `${emoji} → <@&${r.role_id}>`;
        }).join('\n'));
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }
  },
};
EOF_MARKER_src_commands_reactionroles_js

cat > src/services/reactionRoleHandler.js << 'EOF_MARKER_src_services_reactionRoleHandler_js'
const db = require('../db');
const logger = require('../utils/logger');

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
      });
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
EOF_MARKER_src_services_reactionRoleHandler_js

echo "Files written. Run: npm install @napi-rs/canvas @fontsource/inter"
