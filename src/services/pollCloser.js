const { EmbedBuilder } = require('discord.js');
const db = require('../db');
const logger = require('../utils/logger');
const { buildPollDescription } = require('../utils/pollFormat');

let running = false;

async function closePollNow(client, pollId) {
  const poll = db.getPoll(pollId);
  if (!poll || poll.status === 'closed') return;

  db.closePoll(pollId);

  const counts = db.getVoteCounts(pollId, poll.choices.length);
  const total = counts.reduce((a, b) => a + b, 0);
  const maxVotes = Math.max(...counts, 0);
  const winners = maxVotes > 0 ? poll.choices.filter((_, i) => counts[i] === maxVotes) : [];

  const closedEmbed = new EmbedBuilder()
    .setColor(0x57f287)
    .setTitle(`📊 ${poll.question}`)
    .setDescription(buildPollDescription(poll.choices, counts))
    .setFooter({ text: `Poll closed • ${total} total vote${total === 1 ? '' : 's'}` });

  try {
    const channel = await client.channels.fetch(poll.channel_id);

    if (poll.message_id) {
      const message = await channel.messages.fetch(poll.message_id).catch(() => null);
      if (message) await message.edit({ embeds: [closedEmbed], components: [] }).catch(() => {});
    }

    const announceLines = winners.length === 0
      ? `No votes were cast.`
      : winners.length === 1
        ? `🏆 **Winner:** ${winners[0]} (${maxVotes} vote${maxVotes === 1 ? '' : 's'})`
        : `🏆 **Tied winners:** ${winners.join(', ')} (${maxVotes} votes each)`;

    const jumpLink = poll.message_id ? `https://discord.com/channels/${poll.guild_id}/${poll.channel_id}/${poll.message_id}` : null;

    await channel.send({
      content: `📊 Poll closed — **${poll.question}**\n${announceLines}${jumpLink ? `\n${jumpLink}` : ''}`,
    });
  } catch (err) {
    logger.error(`Failed to post results for poll ${pollId}:`, err);
  }
}

async function checkOnce(client) {
  if (running) return;
  running = true;
  try {
    const nowTs = Math.floor(Date.now() / 1000);
    const duePolls = db.listOpenPollsPastClose(nowTs);
    for (const pollId of duePolls) {
      await closePollNow(client, pollId);
    }
  } catch (err) {
    logger.error('Poll closer error:', err);
  } finally {
    running = false;
  }
}

function start(client) {
  logger.info('Starting poll auto-closer (checks every 60s)');
  checkOnce(client);
  setInterval(() => checkOnce(client), 60_000);
}

module.exports = { start, closePollNow };
