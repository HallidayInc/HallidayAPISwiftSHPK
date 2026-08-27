import express from "express";

const app = express();
app.use(express.json({ limit: "256kb" }));
const port = process.env.PORT || 3000;
const alchemyKey = process.env.ALCHEMY_API_KEY;
const hallidayKey = process.env.HALLIDAY_API_KEY;

const BALANCE_TTL = 15_000;
const PRICE_TTL = 60_000;
const MAX_PAGES = 5;
const MAX_BALANCES = 200;
const DECIMALS_TTL = 24 * 60 * 60 * 1000;
const SPL_PROGRAMS = [
  "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
  "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
];
const ASSETS_TTL = 60 * 60 * 1000;
const TRANSFER_TTL = 30_000;
const TRANSFER_DEPTH = 10;

// Bridged variants have no price feed of their own but track the asset they represent.
const PRICE_ALIASES = { USDCE: "USDC", USDT0: "USDT" };

// Alchemy keys its price response by uppercase symbol, so lookups have to match that.
function priceKey(symbol) {
  const upper = String(symbol).toUpperCase();
  return PRICE_ALIASES[upper] ?? upper;
}

// Alchemy serves RPC for these but does not index them in the Data API, so their balances
// are read one asset at a time off Halliday's list instead.
const RPC_ONLY = {
  megaeth: "megaeth-mainnet",
  pharos: "pharos-mainnet",
  stable: "stable-mainnet",
  tempo: "tempo-mainnet",
};

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

function hallidayAssets() {
  return cached("halliday:assets", ASSETS_TTL, async () => {
    if (!hallidayKey) return [];
    const { ok, body } = await fetchJson("https://v2.prod.halliday.xyz/assets", {
      headers: { Authorization: `Bearer ${hallidayKey}` },
    });
    if (!ok) return [];
    return Array.isArray(body) ? body : Object.values(body ?? {});
  });
}

async function rpcResult(url, method, params) {
  const { ok, body } = await fetchJson(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  return ok ? body?.result ?? null : null;
}

async function rpcBalances(evm) {
  if (!evm || !alchemyKey) return [];
  const assets = await hallidayAssets();
  const padded = evm.slice(2).toLowerCase().padStart(64, "0");

  const found = await Promise.all(
    Object.entries(RPC_ONLY).map(async ([chain, network]) => {
      const url = `https://${network}.g.alchemy.com/v2/${alchemyKey}`;
      const rows = await Promise.all(
        assets
          .filter((asset) => asset.chain === chain)
          .map(async (asset) => {
            const native = String(asset.address).toLowerCase() === "0x";
            // balanceOf(address)
            const raw = native
              ? await rpcResult(url, "eth_getBalance", [evm, "latest"])
              : await rpcResult(url, "eth_call", [{ to: asset.address, data: `0x70a08231${padded}` }, "latest"]);
            if (!raw || raw === "0x") return null;
            const amount = toAmount(BigInt(raw), asset.decimals);
            if (!amount) return null;
            return {
              chain,
              address: native ? "0x" : asset.address,
              symbol: asset.symbol,
              logo: asset.image_url ?? null,
              decimals: asset.decimals,
              amount,
            };
          }),
      );
      return rows.filter(Boolean);
    }),
  );

  const flat = found.flat();
  if (!flat.length) return [];
  const table = await prices([...new Set(flat.map((row) => priceKey(row.symbol)))]);
  return flat.map((row) => ({ ...row, usd: usdValue(row.amount, table[priceKey(row.symbol)]) }));
}

// The Data API omits the native row for some Solana wallets, so it is read straight from
// the RPC and deduped against whatever the Data API did return.
async function solanaNative(address) {
  if (!address || !alchemyKey) return [];
  const result = await rpcResult(`https://solana-mainnet.g.alchemy.com/v2/${alchemyKey}`, "getBalance", [address]);
  const lamports = result?.value;
  if (!lamports) return [];
  const amount = toAmount(BigInt(lamports), NATIVE.solana.decimals);
  if (!amount) return [];
  const table = await prices([NATIVE.solana.symbol]);
  return [{
    chain: "solana",
    address: "0x",
    symbol: NATIVE.solana.symbol,
    logo: null,
    decimals: NATIVE.solana.decimals,
    amount,
    usd: usdValue(amount, table[NATIVE.solana.symbol]),
  }];
}

// Same gap as the native row: a freshly created token account may not be indexed yet.
// Restricted to mints Halliday lists, so a wallet full of spam accounts stays manageable.
async function solanaTokens(address) {
  if (!address || !alchemyKey) return [];
  const assets = await hallidayAssets();
  const known = new Map(
    assets.filter((asset) => asset.chain === "solana").map((asset) => [asset.address, asset]),
  );
  if (!known.size) return [];

  const url = `https://solana-mainnet.g.alchemy.com/v2/${alchemyKey}`;
  const lists = await Promise.all(
    SPL_PROGRAMS.map((programId) =>
      rpcResult(url, "getTokenAccountsByOwner", [address, { programId }, { encoding: "jsonParsed" }]),
    ),
  );

  const rows = [];
  for (const list of lists) {
    for (const account of list?.value ?? []) {
      const info = account?.account?.data?.parsed?.info;
      const asset = info && known.get(info.mint);
      const amount = info?.tokenAmount?.uiAmountString;
      if (!asset || !amount || Number(amount) === 0) continue;
      rows.push({
        chain: "solana",
        address: info.mint,
        symbol: asset.symbol,
        logo: asset.image_url ?? null,
        decimals: info.tokenAmount.decimals ?? asset.decimals,
        amount,
      });
    }
  }
  if (!rows.length) return [];

  const table = await prices([...new Set(rows.map((row) => priceKey(row.symbol)))]);
  return rows.map((row) => ({ ...row, usd: usdValue(row.amount, table[priceKey(row.symbol)]) }));
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

app.get("/health", (req, res) => {
  res.json({ ok: true, alchemy: Boolean(alchemyKey), cached: cache.size });
});

app.get("/balances", async (req, res) => {
  const { evm = "", solana = "" } = req.query;
  if (!evm && !solana) {
    return res.status(400).json({ error: "supply at least one address" });
  }

  const key = `balances:${evm}|${solana}`;
  const payload = await cached(key, BALANCE_TTL, async () => {
    const sources = [
      ["alchemy", () => alchemyBalances(evm, solana)],
      ["rpc", () => rpcBalances(evm)],
      ["solana", () => solanaNative(solana)],
      ["solana-tokens", () => solanaTokens(solana)],
    ];

    const settled = await Promise.allSettled(sources.map(([, run]) => run()));
    const balances = [];
    const errors = [];
    settled.forEach((result, index) => {
      if (result.status === "fulfilled") balances.push(...result.value);
      else errors.push({ source: sources[index][0], message: String(result.reason) });
    });

    // Sources can overlap, so the first row for a given asset wins.
    const seen = new Set();
    const unique = balances.filter((row) => {
      const key = `${row.chain}:${String(row.address).toLowerCase()}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });

    unique.sort((a, b) => Number(b.usd) - Number(a.usd));
    const truncated = unique.length > MAX_BALANCES;
    return { balances: unique.slice(0, MAX_BALANCES), truncated, errors };
  });

  res.json(payload);
});

// --- Wallet transaction history -------------------------------------------------------
// Each family reports movement differently, so every source normalises to the same row:
// { chain, hash, direction, symbol, amount, timestamp }.

async function evmTransfers(address) {
  if (!address || !alchemyKey) return [];
  const networks = Object.entries(ALCHEMY_NETWORKS).filter(([chain]) => chain !== "solana");
  const lists = await Promise.all(
    networks.flatMap(([chain, network]) =>
      // Sent and received are separate queries; there is no "either" filter.
      [["fromAddress", "out"], ["toAddress", "in"]].map(async ([field, direction]) => {
        const params = {
          [field]: address,
          category: ["external", "erc20"],
          maxCount: `0x${TRANSFER_DEPTH.toString(16)}`,
          order: "desc",
          withMetadata: true,
        };
        const result = await rpcResult(
          `https://${network}.g.alchemy.com/v2/${alchemyKey}`,
          "alchemy_getAssetTransfers",
          [params],
        );
        return (result?.transfers ?? [])
          .filter((row) => row.value)
          .map((row) => ({
            chain,
            hash: row.hash,
            direction,
            symbol: row.asset ?? "",
            amount: String(row.value),
            timestamp: row.metadata?.blockTimestamp ?? null,
            counterparty: direction === "out" ? row.to ?? null : row.from ?? null,
          }));
      }),
    ),
  );
  return lists.flat();
}

async function solanaTransfers(address) {
  if (!address || !alchemyKey) return [];
  const url = `https://solana-mainnet.g.alchemy.com/v2/${alchemyKey}`;
  const signatures = await rpcResult(url, "getSignaturesForAddress", [address, { limit: TRANSFER_DEPTH }]);
  if (!Array.isArray(signatures)) return [];

  const assets = await hallidayAssets();
  const mints = new Map(assets.filter((a) => a.chain === "solana").map((a) => [a.address, a.symbol]));

  const rows = await Promise.all(
    signatures.map(async (entry) => {
      const tx = await rpcResult(url, "getTransaction", [
        entry.signature,
        { encoding: "jsonParsed", maxSupportedTransactionVersion: 0 },
      ]);
      const meta = tx?.meta;
      if (!meta || meta.err) return null;
      const stamp = entry.blockTime ? new Date(entry.blockTime * 1000).toISOString() : null;

      // A token movement is more meaningful than the lamport change that paid for it.
      const before = (meta.preTokenBalances ?? []).find((b) => b.owner === address);
      const after = (meta.postTokenBalances ?? []).find((b) => b.owner === address);
      if (before || after) {
        const delta = Number(after?.uiTokenAmount?.uiAmountString ?? 0) - Number(before?.uiTokenAmount?.uiAmountString ?? 0);
        if (delta !== 0) {
          const mint = after?.mint ?? before?.mint;
          return {
            chain: "solana",
            hash: entry.signature,
            direction: delta > 0 ? "in" : "out",
            symbol: mints.get(mint) ?? "SPL",
            amount: String(Math.abs(delta)),
            timestamp: stamp,
          };
        }
      }

      const keys = (tx.transaction?.message?.accountKeys ?? []).map((k) => (typeof k === "string" ? k : k.pubkey));
      const index = keys.indexOf(address);
      if (index < 0) return null;
      const delta = (meta.postBalances[index] - meta.preBalances[index]) / 10 ** NATIVE.solana.decimals;
      if (!delta) return null;
      return {
        chain: "solana",
        hash: entry.signature,
        direction: delta > 0 ? "in" : "out",
        symbol: NATIVE.solana.symbol,
        amount: String(Math.abs(delta)),
        timestamp: stamp,
      };
    }),
  );
  return rows.filter(Boolean);
}

app.get("/transfers", async (req, res) => {
  const { evm = "", solana = "" } = req.query;
  const offset = Math.max(0, Number(req.query.offset) || 0);
  const limit = Math.min(50, Math.max(1, Number(req.query.limit) || 10));

  const key = `transfers:${evm}|${solana}`;
  const all = await cached(key, TRANSFER_TTL, async () => {
    const settled = await Promise.allSettled([
      evmTransfers(evm),
      solanaTransfers(solana),
    ]);
    const rows = settled.flatMap((result) => (result.status === "fulfilled" ? result.value : []));

    // The same transfer can arrive from both the sent and received query.
    const seen = new Set();
    const unique = rows.filter((row) => {
      const id = `${row.chain}:${row.hash}:${row.direction}:${row.amount}`;
      if (seen.has(id)) return false;
      seen.add(id);
      return true;
    });
    unique.sort((a, b) => new Date(b.timestamp ?? 0) - new Date(a.timestamp ?? 0));
    return unique;
  });

  res.json({
    transfers: all.slice(offset, offset + limit),
    total: all.length,
    done: offset + limit >= all.length,
  });
});

// Signing happens in the app; these exist so the provider keys do not have to.
const SOLANA_METHODS = new Set([
  "getLatestBlockhash",
  "getAccountInfo",
  "getMinimumBalanceForRentExemption",
  "sendTransaction",
]);

app.post("/solana/rpc", async (req, res) => {
  const { method, params = [] } = req.body ?? {};
  if (!SOLANA_METHODS.has(method)) {
    return res.status(400).json({ error: `method not allowed: ${method}` });
  }
  const { ok, status, body } = await fetchJson(`https://solana-mainnet.g.alchemy.com/v2/${alchemyKey}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  res.status(ok ? 200 : status).json(body ?? { error: "no response" });
});

app.listen(port, () => {
  console.log(`halliday demo server listening on ${port}`);
});
