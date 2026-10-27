#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ -e .env ]]; then
  printf '.env already exists; retained.\n'
  exit 0
fi
umask 077
node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
const text = readFileSync('.env.example', 'utf8').replace('CHANGE_ME_before_starting_9!', `Aa9!${randomBytes(24).toString('hex')}`);
writeFileSync('.env', text, { flag: 'wx', mode: 0o600 });
console.log('Created .env with a random local database password.');
JS
