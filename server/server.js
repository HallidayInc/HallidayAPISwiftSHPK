import express from "express";

const app = express();
app.use(express.json({ limit: "256kb" }));
const port = process.env.PORT || 3000;
const alchemyKey = process.env.ALCHEMY_API_KEY;
const tronKey = process.env.TRONGRID_API_KEY;
const blockcypherToken = process.env.BLOCKCYPHER_TOKEN;
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
const TRON_BASE = `https://tron-mainnet.g.alchemy.com/v2/${alchemyKey}`;
// A native transfer is around this size, and bandwidth beyond the free allowance costs
// 1000 sun per byte.
const TRON_TRANSFER_BYTES = 300;
const SUN_PER_BYTE = 1000;
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

async function bitcoinTransfers(address) {
  if (!address) return [];
  const token = blockcypherToken ? `&token=${blockcypherToken}` : "";
  const { ok, body } = await fetchJson(`https://api.blockcypher.com/v1/btc/main/addrs/${address}?limit=50${token}`);
  if (!ok) return [];
  // A ref with tx_output_n set is money arriving; tx_input_n set is money leaving.
  return (body?.txrefs ?? []).slice(0, TRANSFER_DEPTH * 2).map((ref) => ({
    chain: "bitcoin",
    hash: ref.tx_hash,
    direction: ref.tx_output_n >= 0 ? "in" : "out",
    symbol: "BTC",
    amount: String(ref.value / 10 ** 8),
    timestamp: ref.confirmed ?? null,
  }));
}

async function tronTransfers(address) {
  if (!address) return [];
  const base = "https://api.trongrid.io/v1/accounts";
  const headers = tronKey ? { "TRON-PRO-API-KEY": tronKey } : {};
  const [native, trc20] = await Promise.all([
    fetchJson(`${base}/${address}/transactions?limit=${TRANSFER_DEPTH}`, { headers }),
    fetchJson(`${base}/${address}/transactions/trc20?limit=${TRANSFER_DEPTH}`, { headers }),
  ]);

  const rows = [];
  for (const row of trc20.ok ? trc20.body?.data ?? [] : []) {
    const decimals = Number(row.token_info?.decimals ?? 6);
    rows.push({
      chain: "tron",
      hash: row.transaction_id,
      direction: row.to === address ? "in" : "out",
      symbol: row.token_info?.symbol ?? "TRC20",
      amount: String(Number(row.value) / 10 ** decimals),
      timestamp: row.block_timestamp ? new Date(row.block_timestamp).toISOString() : null,
      counterparty: row.to === address ? row.from ?? null : row.to ?? null,
    });
  }
  for (const row of native.ok ? native.body?.data ?? [] : []) {
    const contract = row.raw_data?.contract?.[0];
    if (contract?.type !== "TransferContract") continue;
    const value = contract.parameter?.value;
    if (!value?.amount) continue;
    rows.push({
      chain: "tron",
      hash: row.txID,
      direction: value.owner_address === address ? "out" : "in",
      symbol: "TRX",
      amount: String(value.amount / 10 ** 6),
      timestamp: row.block_timestamp ? new Date(row.block_timestamp).toISOString() : null,
    });
  }
  return rows;
}

app.get("/transfers", async (req, res) => {
  const { evm = "", solana = "", bitcoin = "", tron = "" } = req.query;
  const offset = Math.max(0, Number(req.query.offset) || 0);
  const limit = Math.min(50, Math.max(1, Number(req.query.limit) || 10));

  const key = `transfers:${evm}|${solana}|${bitcoin}|${tron}`;
  const all = await cached(key, TRANSFER_TTL, async () => {
    const settled = await Promise.allSettled([
      evmTransfers(evm),
      solanaTransfers(solana),
      bitcoinTransfers(bitcoin),
      tronTransfers(tron),
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

app.get("/bitcoin/utxos", async (req, res) => {
  const address = String(req.query.address ?? "");
  if (!address) return res.status(400).json({ error: "address required" });

  const token = blockcypherToken ? `&token=${blockcypherToken}` : "";
  const [unspent, chain] = await Promise.all([
    fetchJson(`https://api.blockcypher.com/v1/btc/main/addrs/${address}?unspentOnly=true&includeScript=true&limit=2000${token}`),
    fetchJson("https://api.blockcypher.com/v1/btc/main"),
  ]);
  if (!unspent.ok) return res.status(unspent.status).json({ error: "blockcypher rejected the request" });

  // WalletCore wants the outpoint hash in little-endian, which is the reverse of the
  // big-endian form block explorers display.
  const utxos = (unspent.body?.txrefs ?? [])
    .filter((ref) => ref.script)
    .map((ref) => ({
      hash: ref.tx_hash.match(/../g).reverse().join(""),
      index: ref.tx_output_n,
      value: ref.value,
      script: ref.script,
    }));

  const perKb = chain.body?.medium_fee_per_kb ?? 2000;
  res.json({ utxos, feePerByte: Math.max(2, Math.ceil(perKb / 1000)) });
});

app.post("/bitcoin/broadcast", async (req, res) => {
  const hex = String(req.body?.hex ?? "");
  if (!hex) return res.status(400).json({ error: "hex required" });
  const token = blockcypherToken ? `?token=${blockcypherToken}` : "";
  const { ok, status, body } = await fetchJson(`https://api.blockcypher.com/v1/btc/main/txs/push${token}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ tx: hex }),
  });
  if (!ok) return res.status(status).json({ error: body?.error ?? "broadcast failed" });
  res.json({ txid: body?.tx?.hash });
});

function tronHeaders() {
  return { "Content-Type": "application/json" };
}

app.get("/tron/block", async (req, res) => {
  const { ok, status, body } = await fetchJson(`${TRON_BASE}/wallet/getnowblock`, {
    method: "POST",
    headers: tronHeaders(),
    body: "{}",
  });
  const raw = body?.block_header?.raw_data;
  if (!ok || !raw) return res.status(ok ? 502 : status).json({ error: "could not read the current block" });
  res.json({
    number: raw.number,
    timestamp: raw.timestamp,
    txTrieRoot: raw.txTrieRoot,
    parentHash: raw.parentHash,
    witnessAddress: raw.witness_address,
    version: raw.version,
  });
});

// Tron meters bandwidth rather than charging a gas price, and every account gets a free
// daily allowance, so a transfer often costs nothing at all.
app.get("/tron/resource", async (req, res) => {
  const address = String(req.query.address ?? "");
  if (!address) return res.status(400).json({ error: "address required" });
  const { ok, body } = await fetchJson(`${TRON_BASE}/wallet/getaccountresource`, {
    method: "POST",
    headers: tronHeaders(),
    body: JSON.stringify({ address, visible: true }),
  });
  if (!ok) return res.status(502).json({ error: "could not read account resources" });
  const free = (body?.freeNetLimit ?? 0) - (body?.freeNetUsed ?? 0);
  const staked = (body?.NetLimit ?? 0) - (body?.NetUsed ?? 0);
  const available = Math.max(0, free) + Math.max(0, staked);
  const sun = available >= TRON_TRANSFER_BYTES ? 0 : TRON_TRANSFER_BYTES * SUN_PER_BYTE;
  res.json({ bandwidth: available, sun });
});

app.post("/tron/broadcast", async (req, res) => {
  const { ok, status, body } = await fetchJson(`${TRON_BASE}/wallet/broadcasttransaction`, {
    method: "POST",
    headers: tronHeaders(),
    body: JSON.stringify(req.body ?? {}),
  });
  if (!ok || body?.result !== true) {
    const message = body?.message ? Buffer.from(body.message, "hex").toString() : "broadcast failed";
    return res.status(ok ? 502 : status).json({ error: message });
  }
  res.json({ txid: body.txid });
});

app.listen(port, () => {
  console.log(`halliday demo server listening on ${port}`);
});
