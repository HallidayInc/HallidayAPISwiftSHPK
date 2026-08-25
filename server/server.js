import express from "express";

const app = express();
const port = process.env.PORT || 3000;
const alchemyKey = process.env.ALCHEMY_API_KEY;
const tronKey = process.env.TRONGRID_API_KEY;
const blockcypherToken = process.env.BLOCKCYPHER_TOKEN;

const BALANCE_TTL = 15_000;
const PRICE_TTL = 60_000;
const MAX_PAGES = 5;
const MAX_BALANCES = 200;
const DECIMALS_TTL = 24 * 60 * 60 * 1000;

const ALCHEMY_NETWORKS = {
  arbitrum: "arb-mainnet",
  avalanche: "avax-mainnet",
  base: "base-mainnet",
  bsc: "bnb-mainnet",
  ethereum: "eth-mainnet",
  hyperevm: "hyperliquid-mainnet",
  monad: "monad-mainnet",
  optimism: "opt-mainnet",
  polygon: "matic-mainnet",
  robinhood: "robinhood-mainnet",
  solana: "solana-mainnet",
  unichain: "unichain-mainnet",
  world: "worldchain-mainnet",
};

const CHAIN_BY_NETWORK = Object.fromEntries(
  Object.entries(ALCHEMY_NETWORKS).map(([chain, network]) => [network, chain]),
);

const NATIVE = {
  arbitrum: { symbol: "ETH", decimals: 18 },
  avalanche: { symbol: "AVAX", decimals: 18 },
  base: { symbol: "ETH", decimals: 18 },
  bsc: { symbol: "BNB", decimals: 18 },
  ethereum: { symbol: "ETH", decimals: 18 },
  hyperevm: { symbol: "HYPE", decimals: 18 },
  monad: { symbol: "MON", decimals: 18 },
  optimism: { symbol: "ETH", decimals: 18 },
  polygon: { symbol: "POL", decimals: 18 },
  robinhood: { symbol: "ETH", decimals: 18 },
  solana: { symbol: "SOL", decimals: 9 },
  unichain: { symbol: "ETH", decimals: 18 },
  world: { symbol: "ETH", decimals: 18 },
};

const TRC20 = {
  TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t: { symbol: "USDT", decimals: 6 },
};

const cache = new Map();
const inflight = new Map();

function cached(key, ttl, work) {
  const hit = cache.get(key);
  if (hit && hit.expires > Date.now()) return hit.value;
  if (inflight.has(key)) return inflight.get(key);

  const pending = (async () => {
    try {
      const value = await work();
      cache.set(key, { value, expires: Date.now() + ttl });
      return value;
    } finally {
      inflight.delete(key);
    }
  })();

  inflight.set(key, pending);
  return pending;
}

async function fetchJson(url, options) {
  const response = await fetch(url, options);
  const body = await response.json().catch(() => null);
  return { ok: response.ok, status: response.status, body };
}

function toAmount(raw, decimals) {
  const value = BigInt(raw);
  if (value === 0n) return null;
  const base = 10n ** BigInt(decimals);
  const fraction = (value % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return fraction ? `${value / base}.${fraction}` : `${value / base}`;
}

function usdValue(amount, price) {
  if (!amount || !price) return "0";
  return String(Number(amount) * Number(price));
}

async function alchemyBalances(evm, solana) {
  const addresses = [];
  const evmNetworks = Object.entries(ALCHEMY_NETWORKS)
    .filter(([chain]) => chain !== "solana")
    .map(([, network]) => network);
  if (evm) addresses.push({ address: evm, networks: evmNetworks });
  if (solana) addresses.push({ address: solana, networks: [ALCHEMY_NETWORKS.solana] });
  if (!addresses.length) return [];

  const url = `https://api.g.alchemy.com/data/v1/${alchemyKey}/assets/tokens/by-address`;
  const rows = [];
  let pageKey;
  let page = 0;

  do {
    const payload = { addresses, withMetadata: true, withPrices: true };
    if (pageKey) payload.pageKey = pageKey;
    const { ok, body } = await fetchJson(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!ok || !body?.data) break;
    rows.push(...body.data.tokens);
    pageKey = body.data.pageKey;
    page += 1;
    if (page >= MAX_PAGES && pageKey) {
      console.warn(`alchemy: stopped at ${MAX_PAGES} pages, more tokens remain`);
      break;
    }
  } while (pageKey);

  const priced = await Promise.all(rows.map(async (row) => {
    const chain = CHAIN_BY_NETWORK[row.network];
    if (!chain) return null;
    const native = NATIVE[chain];
    const decimals = row.tokenMetadata?.decimals
      ?? (row.tokenAddress ? await tokenDecimals(row.network, row.tokenAddress) : null)
      ?? native?.decimals
      ?? 18;
    const amount = toAmount(row.tokenBalance, decimals);
    if (!amount) return null;
    return {
      chain,
      address: row.tokenAddress ?? "0x",
      symbol: row.tokenMetadata?.symbol ?? native?.symbol ?? "?",
      logo: row.tokenMetadata?.logo ?? null,
      decimals,
      amount,
      usd: usdValue(amount, row.tokenPrices?.[0]?.value),
    };
  }));
  return priced.filter(Boolean);
}

// Alchemy metadata omits decimals for some tokens. decimals() is immutable, so ask the
// contract directly and keep the answer.
function tokenDecimals(network, address) {
  return cached(`decimals:${network}:${address}`, DECIMALS_TTL, async () => {
    const { ok, body } = await fetchJson(`https://${network}.g.alchemy.com/v2/${alchemyKey}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [{ to: address, data: "0x313ce567" }, "latest"],
      }),
    });
    const result = ok ? body?.result : null;
    if (!result || result === "0x") return null;
    const value = Number(BigInt(result));
    return value >= 0 && value <= 36 ? value : null;
  });
}

function prices(symbols) {
  return cached(`prices:${symbols.join(",")}`, PRICE_TTL, async () => {
    const query = symbols.map((symbol) => `symbols=${symbol}`).join("&");
    const { ok, body } = await fetchJson(
      `https://api.g.alchemy.com/prices/v1/${alchemyKey}/tokens/by-symbol?${query}`,
    );
    if (!ok) return {};
    return Object.fromEntries(
      (body?.data ?? []).map((entry) => [entry.symbol, entry.prices?.[0]?.value ?? "0"]),
    );
  });
}

async function blockcypherBalance(coin, chain, symbol, address) {
  const token = blockcypherToken ? `?token=${blockcypherToken}` : "";
  const { ok, body } = await fetchJson(
    `https://api.blockcypher.com/v1/${coin}/main/addrs/${address}/balance${token}`,
  );
  if (!ok || typeof body?.final_balance !== "number") return [];
  const amount = toAmount(BigInt(body.final_balance), 8);
  if (!amount) return [];
  const price = (await prices([symbol]))[symbol];
  return [{ chain, address: "0x", symbol, logo: null, decimals: 8, amount, usd: usdValue(amount, price) }];
}

async function tronBalances(address) {
  const headers = tronKey ? { "TRON-PRO-API-KEY": tronKey } : undefined;
  const { ok, body } = await fetchJson(
    `https://api.trongrid.io/v1/accounts/${address}`,
    { headers },
  );
  if (!ok) return [];
  const account = body?.data?.[0];
  if (!account) return [];

  const out = [];
  const trx = toAmount(BigInt(account.balance ?? 0), 6);
  if (trx) {
    const price = (await prices(["TRX"]))["TRX"];
    out.push({ chain: "tron", address: "0x", symbol: "TRX", logo: null, decimals: 6, amount: trx, usd: usdValue(trx, price) });
  }

  for (const entry of account.trc20 ?? []) {
    for (const [contract, raw] of Object.entries(entry)) {
      const meta = TRC20[contract];
      if (!meta) continue;
      const amount = toAmount(BigInt(raw), meta.decimals);
      if (!amount) continue;
      const price = (await prices([meta.symbol]))[meta.symbol];
      out.push({
        chain: "tron",
        address: contract.toLowerCase(),
        symbol: meta.symbol,
        logo: null,
        decimals: meta.decimals,
        amount,
        usd: usdValue(amount, price),
      });
    }
  }
  return out;
}

async function lighterBalance(address) {
  const { ok, body } = await fetchJson(
    `https://mainnet.zklighter.elliot.ai/api/v1/account?by=l1_address&value=${address}`,
  );
  // 21100 simply means this wallet has never opened a Lighter account.
  if (!ok || body?.code === 21100) return [];
  const collateral = body?.accounts?.[0]?.collateral;
  if (!collateral || Number(collateral) === 0) return [];
  return [{
    chain: "lighter",
    address: "0x",
    symbol: "USDC",
    logo: null,
    decimals: 6,
    amount: String(Number(collateral)),
    usd: String(Number(collateral)),
  }];
}

app.get("/health", (req, res) => {
  res.json({ ok: true, alchemy: Boolean(alchemyKey), cached: cache.size });
});

app.get("/balances", async (req, res) => {
  const { evm = "", solana = "", bitcoin = "", tron = "" } = req.query;
  if (!evm && !solana && !bitcoin && !tron) {
    return res.status(400).json({ error: "supply at least one address" });
  }

  const key = `balances:${evm}|${solana}|${bitcoin}|${tron}`;
  const payload = await cached(key, BALANCE_TTL, async () => {
    const sources = [
      ["alchemy", () => alchemyBalances(evm, solana)],
      ["bitcoin", () => (bitcoin ? blockcypherBalance("btc", "bitcoin", "BTC", bitcoin) : [])],
      ["tron", () => (tron ? tronBalances(tron) : [])],
      ["lighter", () => (evm ? lighterBalance(evm) : [])],
    ];

    const settled = await Promise.allSettled(sources.map(([, run]) => run()));
    const balances = [];
    const errors = [];
    settled.forEach((result, index) => {
      if (result.status === "fulfilled") balances.push(...result.value);
      else errors.push({ source: sources[index][0], message: String(result.reason) });
    });

    balances.sort((a, b) => Number(b.usd) - Number(a.usd));
    const truncated = balances.length > MAX_BALANCES;
    return { balances: balances.slice(0, MAX_BALANCES), truncated, errors };
  });

  res.json(payload);
});

app.listen(port, () => {
  console.log(`halliday demo server listening on ${port}`);
});
