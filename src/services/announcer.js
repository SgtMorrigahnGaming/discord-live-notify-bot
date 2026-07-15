const { EmbedBuilder } = require('discord.js');
const config = require('../config');
const logger = require('../utils/logger');

function fillTemplate(template, vars) {
  if (!template) return null;
  let out = template;
  for (const [key, val] of Object.entries(vars)) {
    out = out.replaceAll(`{${key}}`, val ?? '');
  }
  return out;
}

async function announceTwitchLive(client, sub, stream, user) {
  const channel = await client.channels.fetch(sub.announce_channel_id).catch(() => null);
  if (!channel) {
    logger.warn(`Twitch announce: channel ${sub.announce_channel_id} not found (guild ${sub.guild_id})`);
    return;
  }

  const url = `https://twitch.tv/${stream.user_login}`;
  const vars = {
    streamer: stream.user_name,
    title: stream.title,
    game: stream.game_name || 'No category',
    url,
  };

  const content = [
    sub.role_id ? `<@&${sub.role_id}>` : null,
    fillTemplate(sub.custom_message, vars) || fillTemplate(config.twitch.defaultMessage, vars),
  ].filter(Boolean).join(' ');

  const thumbnail = stream.thumbnail_url
    ? `${stream.thumbnail_url
        .replace('{width}', '1280')
        .replace('{height}', '720')}?v=${encodeURIComponent(stream.started_at || Date.now())}`
    : null;

  const embed = new EmbedBuilder()
    .setColor(0x9146ff)
    .setTitle(stream.title || 'Untitled stream')
    .setURL(url)
    .setAuthor({ name: `${stream.user_name} is live on Twitch`, iconURL: user?.profile_image_url })
    .addFields(
      { name: 'Game', value: stream.game_name || 'N/A', inline: true },
      { name: 'Viewers', value: String(stream.viewer_count ?? 0), inline: true },
    )
    .setImage(thumbnail)
    .setTimestamp(new Date(stream.started_at));

  await channel.send({ content, embeds: [embed] }).catch(err => {
    logger.error(`Failed to send Twitch announcement in guild ${sub.guild_id}:`, err.message);
  });
}

async function announceYoutubeVideo(client, sub, video) {
  const channel = await client.channels.fetch(sub.announce_channel_id).catch(() => null);
  if (!channel) {
    logger.warn(`YouTube announce: channel ${sub.announce_channel_id} not found (guild ${sub.guild_id})`);
    return;
  }

  const vars = {
    channel: video.channelName,
    title: video.title,
    url: video.url,
  };

  const content = [
    sub.role_id ? `<@&${sub.role_id}>` : null,
   fillTemplate(sub.custom_message, vars) || fillTemplate(config.youtube.defaultMessage, vars),
  ].filter(Boolean).join(' ');

  const embed = new EmbedBuilder()
    .setColor(0xff0000)
    .setTitle(video.title)
    .setURL(video.url)
    .setAuthor({ name: video.channelName })
    .setImage(video.thumbnail || null)
    .setTimestamp(video.published ? new Date(video.published) : new Date());

  await channel.send({ content, embeds: [embed] }).catch(err => {
    logger.error(`Failed to send YouTube announcement in guild ${sub.guild_id}:`, err.message);
  });
}

const SOURCE_STYLE = {
  steam: { label: 'Steam', color: 0x1b2838, gpSourced: true },
  gog: { label: 'GOG', color: 0x8b40e3, gpSourced: true },
  epic: { label: 'Epic Games', color: 0x2a2a2a, gpSourced: false },
};

async function announceFreeGame(client, sub, source, game) {
  const channel = await client.channels.fetch(sub.channel_id).catch(() => null);
  if (!channel) {
    logger.warn(`Free games announce: channel ${sub.channel_id} not found (guild ${sub.guild_id})`);
    return;
  }

  const style = SOURCE_STYLE[source] || { label: source, color: 0x5865f2, gpSourced: false };

  const fields = [{ name: 'Price', value: 'FREE', inline: true }];
  if (style.gpSourced) {
    fields.push({ name: 'Source', value: '[GamerPower.com](https://www.gamerpower.com)', inline: true });
  }

  const embed = new EmbedBuilder()
    .setColor(style.color)
    .setAuthor({ name: style.label })
    .setTitle(`Free Game: ${game.title}`)
    .setURL(game.url)
    .addFields(fields)
    .setImage(game.image || null);

  if (style.gpSourced) {
    embed.setFooter({ text: 'via GamerPower' });
  }

  await channel.send({ embeds: [embed] }).catch(err => {
    logger.error(`Failed to send free games announcement in guild ${sub.guild_id}:`, err.message);
  });
}

module.exports = { announceTwitchLive, announceYoutubeVideo, announceFreeGame };
