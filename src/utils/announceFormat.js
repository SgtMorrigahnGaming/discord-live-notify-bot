const { ChannelType } = require('discord.js');

// Punctuation that commonly trails a #channel or @role at the end of a sentence.
const TRAILING_PUNCT = /[.,!?:;)\]}"']+$/;

// Not preceded by "<", a word character, "&" or "/" — avoids touching raw <#id> / <@&id>
// mentions, e-mail addresses and URL fragments like page#section.
const CHANNEL_RE = /(?<![<\w&/])#([^\s#@<>]+)/g;
const AT_RE = /(?<![<\w&/])@([^\s@#<>]+)/g;
const EVERYONE_RE = /(?<![<\w&/])@(everyone|here)(?!\w)/gi;
const LEADING_PING_RE = /^\s*(?:@(?:everyone|here)(?!\w)[\s,:\-–]*)+/i;

function splitTrailing(token) {
  const m = token.match(TRAILING_PUNCT);
  if (!m) return [token, ''];
  return [token.slice(0, -m[0].length), m[0]];
}

function normalizeRoleName(name) {
  return String(name).toLowerCase().replace(/\s+/g, '_');
}

function findChannel(guild, name) {
  if (!name) return null;
  const wanted = name.toLowerCase();
  const matches = [...guild.channels.cache.values()].filter(
    (c) => c.type !== ChannelType.GuildCategory && c.name && c.name.toLowerCase() === wanted
  );
  if (matches.length === 0) return null;
  // If a text and a voice channel share a name, prefer the text-based one.
  return matches.find((c) => typeof c.isTextBased === 'function' && c.isTextBased()) || matches[0];
}

function findRole(guild, name) {
  if (!name) return null;
  const wanted = normalizeRoleName(name);
  // The @everyone role has the same id as the guild — never resolve to it.
  return guild.roles.cache.find((r) => r.id !== guild.id && normalizeRoleName(r.name) === wanted) || null;
}

/**
 * Turns the plain text a moderator typed into text with real Discord mentions.
 *
 *   #terraria      -> <#channelId>        (clickable channel link)
 *   @Some_Role     -> <@&roleId>          (underscores match spaces in role names)
 *   @everyone/@here stay as-is, and are reported via pingEveryone / pingHere
 *   literal "\n"   -> real line break     (slash-command options are single-line)
 *
 * Anything that can't be matched is left untouched and listed in `unresolved`.
 */
function resolveAnnouncement(rawText, guild) {
  let text = String(rawText).replace(/\\n/g, '\n');
  const roleIds = new Set();
  const unresolved = [];

  // @everyone / @here — Discord only pings the lowercase form, so normalise.
  let pingEveryone = false;
  let pingHere = false;
  text = text.replace(EVERYONE_RE, (_full, which) => {
    const w = which.toLowerCase();
    if (w === 'everyone') pingEveryone = true;
    else pingHere = true;
    return `@${w}`;
  });

  // #channel -> <#id>
  text = text.replace(CHANNEL_RE, (full, token) => {
    const [core, trailing] = splitTrailing(token);
    const direct = findChannel(guild, token);
    if (direct) return `<#${direct.id}>`;
    const stripped = core ? findChannel(guild, core) : null;
    if (stripped) return `<#${stripped.id}>${trailing}`;
    unresolved.push(`#${core || token}`);
    return full;
  });

  // @role -> <@&id>
  text = text.replace(AT_RE, (full, token) => {
    const [core, trailing] = splitTrailing(token);
    const lower = core.toLowerCase();
    if (lower === 'everyone' || lower === 'here') return full;
    const direct = findRole(guild, token);
    if (direct) {
      roleIds.add(direct.id);
      return `<@&${direct.id}>`;
    }
    const stripped = core ? findRole(guild, core) : null;
    if (stripped) {
      roleIds.add(stripped.id);
      return `<@&${stripped.id}>${trailing}`;
    }
    unresolved.push(`@${core || token}`);
    return full;
  });

  return {
    text,
    roleIds: [...roleIds],
    pingEveryone,
    pingHere,
    unresolved: [...new Set(unresolved)],
  };
}

// Builds the allowedMentions object. Only what the announcement itself resolved can ping;
// individual users can never be pinged through /vvc.
function buildAllowedMentions({ pingEveryone, pingHere, roleIds }) {
  return {
    parse: pingEveryone || pingHere ? ['everyone'] : [],
    roles: roleIds,
    users: [],
  };
}

// For embed style: pings must live in the message content (mentions inside an embed
// highlight but never notify), so build that line separately.
function buildPingLine({ pingEveryone, pingHere, roleIds }) {
  const parts = [];
  if (pingEveryone) parts.push('@everyone');
  if (pingHere) parts.push('@here');
  for (const id of roleIds) parts.push(`<@&${id}>`);
  return parts.join(' ');
}

// For embed style: a leading "@everyone " is redundant with the ping line, so drop it from the body.
function stripLeadingPings(text) {
  const stripped = text.replace(LEADING_PING_RE, '');
  return stripped.trim().length > 0 ? stripped : text;
}

module.exports = {
  resolveAnnouncement,
  buildAllowedMentions,
  buildPingLine,
  stripLeadingPings,
};
