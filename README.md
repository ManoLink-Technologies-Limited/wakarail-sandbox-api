# Wakarail sandbox API

The partner-facing HTTP surface of **Wakarail**, the payment-routing engine built by
[ManoLink Technologies Limited](https://github.com/ManoLink-Technologies-Limited): quote a route,
create a transfer, follow its lifecycle, and receive signed webhook callbacks.

This repository contains the published interface only — an OpenAPI description, a quickstart and
example callbacks. The engine's source is proprietary and private.

> **Sandbox only.** No endpoint described here moves real money. Live money is disabled
> (`liveMoneyEnabled: false`), every provider adapter is `NOT_VERIFIED`, and live operation waits on
> Bank of Sierra Leone authorisation, provider agreements and an independent security review.

## What is in here

| Path | What it is |
| --- | --- |
| [`openapi.yaml`](openapi.yaml) | OpenAPI 3.1 description of the sandbox transfer API and its webhook events |
| [`examples/quickstart.sh`](examples/quickstart.sh) | Copy-paste walkthrough: quote → transfer → status → simulated settlement |
| [`examples/webhooks/`](examples/webhooks) | Example callback payloads as the sandbox emits them |
| [`examples/verify-webhook.mjs`](examples/verify-webhook.mjs) | Dependency-free signature check you can drop into your own receiver |

## Model in one minute

1. A partner (an approved channel) sends a **transfer instruction**: wallet network, amount, and the
   two mobile-money accounts involved.
2. Wakarail chooses the route, assigns references and records an immutable event trail.
3. The licensed sponsor and the providers move and settle the money.
4. Wakarail receives **signed provider callbacks** and reconciles the outcome.

Statuses: `CREATED → ROUTING → SUBMITTED → SETTLED`. `FAILED` is reachable from `ROUTING` or
`SUBMITTED`. A settled transfer can later move `REVERSAL_PENDING → REVERSED`.

Customer PINs are never requested or stored. Wakarail does not hold balances, accept deposits or
issue e-money. Account numbers are used in memory only: responses carry **masked** accounts, never
the raw value, and never a reversible fingerprint.

## Authentication

Every request carries your partner API key as a bearer token:

```http
Authorization: Bearer <partner API key>
```

Credentials are issued per partner with an explicit permission set and can be rotated with an
overlap window. Sandbox keys are never valid outside the sandbox.

### Optional request signing

A credential can be issued with an Ed25519 signing key. Such requests must additionally carry:

| Header | Value |
| --- | --- |
| `x-wakarail-timestamp` | Unix time in seconds, exactly 10 digits |
| `x-wakarail-nonce` | 16–128 characters from `A–Z a–z 0–9 _ -`, single use |
| `x-wakarail-content-sha256` | Lowercase hex SHA-256 of the raw body (64 chars) |
| `x-wakarail-signature` | Base64 Ed25519 signature over the canonical string below |

The canonical string is your method, target and key ID joined by newlines — no trailing newline:

```
wakarail-partner-request-v1
POST
/v1/transfers
1763718000
9d1f4c0b7a2e4f83
0f3c…(64 hex)…
sbx_key_01
```

Requests older than 300 seconds, or that reuse a nonce, are refused (`401` / `409`).

## Quickstart

You need a sandbox base URL and partner key from your access pack. The examples use `jq`.

```sh
export WAKARAIL_BASE_URL="https://your-sandbox-host"   # host from your access pack
export WAKARAIL_API_KEY="sbx_..."                      # never commit this

./examples/quickstart.sh
```

The script performs the whole loop:

```sh
# 1. Quote the route and the fee it will apply
curl -sS "$WAKARAIL_BASE_URL/v1/quotes" \
  -H "Authorization: Bearer $WAKARAIL_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"sourceNetwork":"ORANGE_MONEY_SL","destinationNetwork":"AFRIMONEY_SL","amountMinor":25000,"currency":"SLE"}'

# 2. Create the transfer. The idempotency key makes this safe to retry.
curl -sS "$WAKARAIL_BASE_URL/v1/transfers" \
  -H "Authorization: Bearer $WAKARAIL_API_KEY" \
  -H 'content-type: application/json' \
  -H "idempotency-key: 6f1f0b1e-2f0b-4a1c-9d55-3f3a1f0d9a11" \
  -d '{"sourceNetwork":"ORANGE_MONEY_SL","destinationNetwork":"AFRIMONEY_SL","amountMinor":25000,"currency":"SLE","senderAccount":"+23276000001","recipientAccount":"+23277000002"}'

# 3. Read the transfer and its event chain
curl -sS "$WAKARAIL_BASE_URL/v1/transfers/$TRANSFER_ID" \
  -H "Authorization: Bearer $WAKARAIL_API_KEY"

# 4. Simulate the sponsor settling it (sandbox only)
curl -sS -X POST "$WAKARAIL_BASE_URL/sandbox/transfers/$TRANSFER_ID/settle" \
  -H "Authorization: Bearer $WAKARAIL_API_KEY"
```

Amounts are **integer minor units** of SLE: `25000` is 250.00 SLE. Never send floats.

### Idempotency

`POST /v1/transfers` accepts an `idempotency-key` header. Replaying the same key with the same body
returns the original transfer (`200`, `replayed: true`) instead of creating a second one; the same
key with a different body is a `409`. Keys are scoped to your partner account.

### Errors

Failures use one envelope, with a request ID on every response (`x-request-id`):

```json
{ "error": { "code": "TRANSFER_LIMIT_EXCEEDED", "message": "…" } }
```

| Status | Meaning |
| --- | --- |
| `400` | The request is malformed or fails validation |
| `401` | Missing or invalid credential, or an invalid request signature |
| `403` | The credential does not hold the permission the route needs |
| `404` | The resource does not exist **or is not yours** — ownership is never confirmed to another partner |
| `409` | Idempotency conflict, illegal state transition, or a replayed nonce |
| `429` | Rate limited for this credential |

## Callbacks

Each transfer event can produce one durable webhook notification for a partner subscription. The
envelope is stable:

```json
{
  "id": "webhook_1",
  "type": "transfer.transfer_created",
  "createdAt": "2026-11-22T09:15:04.221Z",
  "data": {
    "transferId": "trf_7c1e9b0a4d2f4f8e",
    "partnerId": "partner_sandbox_demo",
    "status": "CREATED",
    "amountMinor": 25000,
    "currency": "SLE",
    "providerReference": null,
    "failureCode": null
  }
}
```

`type` is `transfer.` followed by the event name, lowercased: `transfer.transfer_created` when the
transfer is recorded, and status events such as `transfer.provider_settled` and
`transfer.provider_failed` as the sponsor answers. Payloads carry operational transfer fields only —
no account numbers, raw or hashed.

Every delivery is signed with HMAC-SHA256 (hex) over the webhook ID, a timestamp and the exact
payload bytes, joined with dots, using your subscription's signing secret:

```
signature = hex( HMAC-SHA256( secret, timestamp + "." + webhookId + "." + rawBody ) )
```

Verify against the **raw** body before parsing it, and reject timestamps outside your tolerance:

```sh
node examples/verify-webhook.mjs \
  --secret "$WEBHOOK_SECRET" \
  --webhook-id  "webhook_1" \
  --timestamp  "1763718000" \
  --signature  "9f2c…" \
  --payload    examples/webhooks/transfer-created.json
```

The default sandbox transport records deliveries without contacting your endpoint, so a sandbox
subscription never calls out. Treat the payloads in [`examples/webhooks/`](examples/webhooks) as the
exact shape a live subscription sends.

Deliveries are retried on failure and end in a dead-letter state after the configured attempts; the
attempt history stays queryable rather than being discarded.

## Not in this repository

The engine, its tests, deployment manifests and internal operations tooling are private and
proprietary. Nothing here is source code for the product, and nothing here is a licence to operate a
payment service.

- Security reports: **hello@wakabots.com** with the subject `SECURITY` (see the
  [organisation security policy](https://github.com/ManoLink-Technologies-Limited/.github/blob/main/SECURITY.md)).
  Never open a public issue about a vulnerability.
- Licensing, partnership and pilot enquiries: **hello@wakabots.com**
- Terms for this document: see [LICENSE](LICENSE).

© 2026 ManoLink Technologies Limited. All rights reserved.
