#!/usr/bin/env bash
# Wakarail sandbox quickstart: quote -> create -> read -> simulate settlement.
# Requires: curl, jq. Sandbox only — no real money moves.
set -euo pipefail

: "${WAKARAIL_BASE_URL:?set WAKARAIL_BASE_URL to the sandbox host from your access pack}"
: "${WAKARAIL_API_KEY:?set WAKARAIL_API_KEY to your sandbox partner key}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

api() {
  local method="$1" path="$2"; shift 2
  curl -sS -X "$method" "$WAKARAIL_BASE_URL$path" \
    -H "Authorization: Bearer $WAKARAIL_API_KEY" \
    -H 'content-type: application/json' \
    "$@"
}

IDEMPOTENCY_KEY="$(uuidgen 2>/dev/null || echo "quickstart-$(date +%s)")"

echo "→ Quoting the route"
api POST /v1/quotes -d '{
  "sourceNetwork": "ORANGE_MONEY_SL",
  "destinationNetwork": "AFRIMONEY_SL",
  "amountMinor": 25000,
  "currency": "SLE"
}' | jq '{quote, route}'

echo "→ Creating the transfer (idempotency-key: $IDEMPOTENCY_KEY)"
CREATED="$(api POST /v1/transfers \
  -H "idempotency-key: $IDEMPOTENCY_KEY" \
  -d '{
    "sourceNetwork": "ORANGE_MONEY_SL",
    "destinationNetwork": "AFRIMONEY_SL",
    "amountMinor": 25000,
    "currency": "SLE",
    "senderAccount": "+23276000001",
    "recipientAccount": "+23277000002"
  }')"
echo "$CREATED" | jq '{transfer: {id: .transfer.id, status: .transfer.status, recipientMasked: .transfer.recipientMasked}, replayed, liveMoneyEnabled}'

TRANSFER_ID="$(echo "$CREATED" | jq -r '.transfer.id')"
[ -n "$TRANSFER_ID" ] && [ "$TRANSFER_ID" != "null" ] || { echo "no transfer id returned" >&2; exit 1; }

echo "→ Reading the transfer and its event chain"
api GET "/v1/transfers/$TRANSFER_ID" | jq '{status: .transfer.status, events: [.events[] | {sequence, eventType, toStatus}]}'

echo "→ Simulating the sponsor settling it (sandbox only)"
api POST "/sandbox/transfers/$TRANSFER_ID/settle" | jq '{status: .transfer.status, providerReference: .transfer.providerReference, simulated}'

echo "→ Replaying the same idempotency key (must not create a second transfer)"
api POST /v1/transfers \
  -H "idempotency-key: $IDEMPOTENCY_KEY" \
  -d '{
    "sourceNetwork": "ORANGE_MONEY_SL",
    "destinationNetwork": "AFRIMONEY_SL",
    "amountMinor": 25000,
    "currency": "SLE",
    "senderAccount": "+23276000001",
    "recipientAccount": "+23277000002"
  }' | jq '{id: .transfer.id, status: .transfer.status, replayed}'

echo "Done. Transfer: $TRANSFER_ID"
