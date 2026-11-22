#!/usr/bin/env node

// Verify a Wakarail webhook delivery signature.
//
//   signature = hex( HMAC-SHA256( secret, timestamp + "." + webhookId + "." + rawBody ) )
//
// Verify the raw body before parsing it, then reject stale timestamps.
// Usage:
//   node verify-webhook.mjs --secret S --webhook-id ID --timestamp TS \
//                           --signature SIG --payload ./examples/webhooks/transfer-created.json

import fs from 'node:fs';
import { createHmac, timingSafeEqual } from 'node:crypto';

const MAX_AGE_SECONDS = 5 * 60;

function arg(name) {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? undefined : process.argv[index + 1];
}

const secret = arg('secret');
const webhookId = arg('webhook-id');
const timestamp = arg('timestamp');
const signature = arg('signature');
const payloadPath = arg('payload');

if (!secret || !webhookId || !timestamp || !signature || !payloadPath) {
  console.error('missing argument: need --secret --webhook-id --timestamp --signature --payload');
  process.exit(2);
}

const rawBody = fs.readFileSync(payloadPath, 'utf8');

const expected = createHmac('sha256', secret)
  .update(`${timestamp}.${webhookId}.${rawBody}`)
  .digest('hex');

function sameHex(left, right) {
  const a = Buffer.from(String(left), 'utf8');
  const b = Buffer.from(String(right), 'utf8');
  return a.length === b.length && timingSafeEqual(a, b);
}

if (!sameHex(expected, signature)) {
  console.error('signature mismatch — treat this delivery as untrusted');
  process.exit(1);
}

const age = Math.abs(Date.now() / 1000 - Number(timestamp));
if (!Number.isFinite(age) || age > MAX_AGE_SECONDS) {
  console.error(`timestamp outside tolerance (${Math.round(age)}s) — possible replay`);
  process.exit(1);
}

const event = JSON.parse(rawBody);
console.log(`verified ${event.type} for transfer ${event.data.transferId} (status ${event.data.status})`);
console.log(`webhook id ${webhookId}, signed ${Math.round(age)}s ago`);
