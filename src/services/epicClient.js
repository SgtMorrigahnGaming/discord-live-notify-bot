const logger = require('../utils/logger');

const ENDPOINT = 'https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions';

function isCurrentlyFree(offer) {
  const active = offer.promotions?.promotionalOffers;
  if (!active || active.length === 0) return false;
  return active.some(window =>
    window.promotionalOffers?.some(po => po.discountSetting?.discountPercentage === 0)
  );
}

function bestImage(offer) {
  const images = offer.keyImages || [];
  return (
    images.find(i => i.type === 'OfferImageWide')?.url ||
    images.find(i => i.type === 'Thumbnail')?.url ||
    images[0]?.url ||
    null
  );
}

function buildUrl(offer) {
  const slug = offer.productSlug || offer.catalogNs?.mappings?.[0]?.pageSlug || offer.urlSlug;
  return slug ? `https://store.epicgames.com/en-US/p/${slug}` : 'https://store.epicgames.com/en-US/free-games';
}

/** Returns currently-free games as a normalized array: { externalId, title, description, url, image }. */
async function fetchCurrentFreeGames() {
  const res = await fetch(`${ENDPOINT}?locale=en-US&country=US&allowCountries=US`, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; DiscordLiveNotifyBot/1.0)' },
  });
  if (!res.ok) {
    logger.warn(`Epic free games fetch failed: HTTP ${res.status}`);
    return [];
  }
  const body = await res.json();
  const elements = body?.data?.Catalog?.searchStore?.elements;
  if (!Array.isArray(elements)) {
    logger.warn('Epic free games: unexpected response shape, no elements array found');
    return [];
  }

  return elements
    .filter(isCurrentlyFree)
    .map(offer => ({
      externalId: offer.id || `${offer.namespace}-${offer.title}`,
      title: offer.title,
      description: offer.description || null,
      url: buildUrl(offer),
      image: bestImage(offer),
    }));
}

module.exports = { fetchCurrentFreeGames };
