/**
 * Parses a user-supplied emoji (from a Discord slash command string option, which preserves
 * emoji exactly as typed/picked) into { id, name }.
 * - Custom guild emoji look like <:name:123456789012345678> or <a:name:123...> (animated)
 * - Standard unicode emoji come through as the raw character itself
 * Returns null if the input can't be resolved (e.g. a plain :shortcode: with no ID attached).
 */
function parseEmojiInput(raw) {
  if (!raw) return null;
  const trimmed = raw.trim();

  const customMatch = trimmed.match(/^<a?:(\w+):(\d+)>$/);
  if (customMatch) {
    return { id: customMatch[2], name: customMatch[1] };
  }

  if (trimmed.startsWith(':') && trimmed.endsWith(':')) {
    return null; // bare shortcode with no ID — can't react with this reliably
  }

  return { id: null, name: trimmed };
}

/** Converts a parsed emoji into the string format discord.js's Message#react expects. */
function toReactString(emoji) {
  return emoji.id ? `${emoji.name}:${emoji.id}` : emoji.name;
}

/** Does a discord.js ReactionEmoji/Emoji object match a stored { emoji_id, emoji_name } row? */
function matchesStoredEmoji(row, reactionEmoji) {
  if (row.emoji_id) return row.emoji_id === reactionEmoji.id;
  return !reactionEmoji.id && row.emoji_name === reactionEmoji.name;
}

/** Human-readable display of a parsed emoji, for confirmation messages. */
function displayEmoji(emoji) {
  return emoji.id ? `<:${emoji.name}:${emoji.id}>` : emoji.name;
}

module.exports = { parseEmojiInput, toReactString, matchesStoredEmoji, displayEmoji };
