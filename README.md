# Halliday API — Swift Example

A minimal iOS app demonstrating using the [Halliday](https://halliday.xyz) REST API for deposits, withdrawals, and swaps.

For iPhone, iOS 17+. Built with Xcode 26.

## Setup

Three files hold machine- or account-specific values. Each is gitignored and ships with a
`.example` alongside it, so a fresh clone starts by copying all three:

```
cp Signing.xcconfig.example Signing.xcconfig
cp HallidayDemo.xcodeproj/xcshareddata/xcschemes/HallidayDemo.xcscheme.example \
   HallidayDemo.xcodeproj/xcshareddata/xcschemes/HallidayDemo.xcscheme
cp server/.env.example server/.env
```

Then fill each one in and open `HallidayDemo.xcodeproj`. Copy the scheme **before** opening the
project — Xcode generates an empty scheme when it finds none, and that one has no environment
variables in it.

### 1. `Signing.xcconfig` — code signing

| Setting | Value |
|---|---|
| `DEVELOPMENT_TEAM` | Your 10-character Team ID, from https://developer.apple.com/account under Membership details |
| `PRODUCT_BUNDLE_IDENTIFIER` | Anything you control, e.g. `com.yourname.HallidayDemo` |

The project reads these through `baseConfigurationReference` rather than storing them in
`project.pbxproj`, which is why the pbxproj has no team ID in it. Building without this file
gives an empty bundle identifier and fails at the signing step.

### 2. The scheme — runtime keys

`Config.swift` reads both of these from the process environment, so they live in the scheme's
**Run → Arguments → Environment Variables** (editable in Xcode via Product → Scheme → Edit Scheme):

| Variable | Used for |
|---|---|
| `HALLIDAY_API_KEY` | Deposit, withdraw, and swap flows. Free at https://dashboard.halliday.xyz/ |
| `SERVER_URL` | Base URL of the balance proxy in `server/`. No default — must be set |

The Halliday **public** key (`pk_…`) is designed to ship in clients, so it stays in the app and
calls Halliday directly. It is kept out of git because it is billable to your account, not
because exposing it in a build is unsafe. Never put a secret key here.

`SERVER_URL` has no hardcoded fallback, so balances stay empty until it is set. A plain `http://`
host requires an ATS exception on device — use `https://`.

### 3. `server/.env` — provider keys

Every non-Halliday key lives here and is never bundled into the app. See
[Balance proxy](#balance-proxy) below. You can point `SERVER_URL` at a local `npm start` while
developing.

## Balance proxy

`server/` is a single-file Express app that fans out to the balance providers, normalises the
results, and caches them so the app can poll freely.

```
cd server && npm install && npm start
```

Deploy changes with `server/autoupload/deploy.sh` (rsync, `npm install`, `pm2 restart`, health
check). The pm2 process must be started via `npm start` so that node's `--env-file=.env` flag is
applied — starting `server.js` directly loads no keys and fails silently.

`GET /balances?evm=&solana=&bitcoin=&tron=` returns
`{ balances: [{ chain, address, symbol, amount, usd, logo, decimals }], truncated, errors }`.
`address` is `0x` for a chain's native coin. When Alchemy's metadata omits `decimals` the proxy
reads `decimals()` off the contract and caches the answer for a day, since it never changes.

| Provider | Chains |
|---|---|
| Alchemy Data API | arbitrum, avalanche, base, bsc, ethereum, hyperevm, monad, optimism, polygon, robinhood, solana, unichain, world |
| BlockCypher | bitcoin |
| TronGrid | tron (TRX + known TRC-20) |
| Lighter | lighter |

Not covered: `megaeth`, `pharos`, `stable`.

Responses are cached for 15s and identical in-flight requests are coalesced, so twenty
simultaneous calls produce one upstream fetch. Alchemy paging stops at 5 pages and the response
is capped at 200 balances — wallets holding thousands of spam tokens would otherwise take ~45s.
`truncated` reports when that cap was hit.

## Wallets

On first launch the app generates a 12-word BIP39 mnemonic and derives one address per chain
family — EVM, Solana, Bitcoin, Tron. Wallets persist to `Documents/wallets.json`;
add or delete them from the settings menu.

This is example code. The mnemonic is stored in plaintext and is not protected by the Keychain
or Secure Enclave. Do not put real funds in it.

## Flows

Deposit, withdraw, and swap are the same state machine (`DepositFlow`) in three modes; send and
receive are plain wallet operations that never touch Halliday.

| Flow | Screens |
|---|---|
| Deposit (crypto) | receive token → network → input token → network → amount → quote → QR to pay |
| Deposit (cash) | receive token → network → currency → payment method → amount → quote → hosted onramp |
| Withdraw | input token → network → output → destination address → amount → quote → broadcast |
| Swap | input → output → amount → quote → broadcast |
| Send | token → network → amount → address → review → broadcast |
| Receive | network → QR |

Network screens are skipped when a token exists on only one chain. Assets are filtered by
`/assets/available-inputs` and `/assets/available-outputs` for what is actually routable, then
narrowed again by the app's own symbol and chain allowlists in `AssetStore`.

Payments over $300 USD return a `USER_VERIFY` instruction. The app signs the EIP-712 payload
with the wallet's EVM key and resubmits automatically — the user never sees it.

The cash onramp opens Halliday's `funding_page_url` in an `SFSafariViewController` rather than a
`WKWebView`, because only the former supports Apple Pay on the Web.

## Gas

Withdraw, swap, and send broadcast from the wallet, so they need the chain's gas coin. Deposit
does not — it is paid from outside.

Gas is estimated per transaction with `eth_estimateGas` instead of assuming 21,000, both because
an ERC-20 transfer costs several times that and because [EIP-2780](https://eips.ethereum.org/EIPS/eip-2780)
proposes changing the intrinsic cost. The estimate is padded 25%.

"Max" holds that estimate back when the asset being spent is the gas coin itself. The review
screen blocks the action and explains why when the wallet cannot cover the fee — for a native
send that means `balance < fee + amount`, for a token it means the native balance is short.

Only EVM chains can be sent from. Bitcoin, Solana, and Tron balances display but their sends
throw `SendError.unsupported`.

## Dependencies

[Trust Wallet Core](https://github.com/trustwallet/wallet-core) 4.7.2, pinned by checksum in
`Packages/WalletCore/Package.swift`. [SwiftDraw](https://github.com/swhitty/SwiftDraw) 0.29.0,
because most Halliday token icons are SVG and SwiftUI cannot render SVG natively.

The manifest is local on purpose. The `Package.swift` committed at every wallet-core tag still
points at the 4.2.9 binaries, so depending on the GitHub repo directly resolves a much older
xcframework than the tag implies. The local manifest names the 4.7.2 release assets explicitly.
