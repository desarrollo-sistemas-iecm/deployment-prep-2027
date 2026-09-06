#!/usr/bin/env node
// Emulador local del Extractor/Difusor: firma y envía un corte SQLite al
// contrato REAL de services-prep-2027 (POST /:apiPrefix/cortes — multipart
// `database` + `cutId`/`version`/`activationAt`/`manifest`, manifest con
// firma HMAC-SHA256 embebida, JWT Bearer HS256). Sin dependencias externas:
// usa solo node:crypto, node:fs y los globals fetch/FormData/Blob de Node.
//
// Uso:
//   node send-test-cut.mjs --file corte.db3 [--cut-id ID] [--version 1.0]
//     [--activation-at now|+30s|<ISO8601>] [--base-url http://127.0.0.1:3000]
//     [--hmac-secret S] [--jwt-secret S] [--subject difusor-x]
//     [--invalid-token] [--bad-hash] [--bad-signature] [--corrupt-db] [--no-poll]
//
// Variables de entorno equivalentes: BASE_URL, API_PREFIX,
// CORTES_MANIFEST_HMAC_SECRET, JWT_SECRET, DIFUSOR_SUBJECT.

import { readFileSync } from 'node:fs';
import { createHash, createHmac } from 'node:crypto';

function parseArgs(argv) {
  const args = { activationAt: 'now', version: '1.0' };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    switch (flag) {
      case '--file':
        args.file = argv[++i];
        break;
      case '--cut-id':
        args.cutId = argv[++i];
        break;
      case '--version':
        args.version = argv[++i];
        break;
      case '--activation-at':
        args.activationAt = argv[++i];
        break;
      case '--base-url':
        args.baseUrl = argv[++i];
        break;
      case '--hmac-secret':
        args.hmacSecret = argv[++i];
        break;
      case '--jwt-secret':
        args.jwtSecret = argv[++i];
        break;
      case '--subject':
        args.subject = argv[++i];
        break;
      case '--invalid-token':
        args.invalidToken = true;
        break;
      case '--bad-hash':
        args.badHash = true;
        break;
      case '--bad-signature':
        args.badSignature = true;
        break;
      case '--corrupt-db':
        args.corruptDb = true;
        break;
      case '--no-poll':
        args.noPoll = true;
        break;
      case '--help':
        args.help = true;
        break;
      default:
        throw new Error(`Argumento desconocido: ${flag}`);
    }
  }
  return args;
}

function base64url(input) {
  return Buffer.from(input).toString('base64url');
}

// HS256 manual (sin librerías): igual formato que @nestjs/jwt/jsonwebtoken.
function signHs256Jwt(payload, secret) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = createHmac('sha256', secret)
    .update(signingInput)
    .digest('base64url');
  return `${signingInput}.${signature}`;
}

function resolveActivationAt(value) {
  if (value === 'now') return new Date(Date.now() - 1000).toISOString();
  const relative = /^\+(\d+)s$/.exec(value);
  if (relative) {
    return new Date(Date.now() + Number(relative[1]) * 1000).toISOString();
  }
  return new Date(value).toISOString();
}

async function pollStatus(baseUrl, apiPrefix, cutId, attempts = 20, delayMs = 500) {
  for (let i = 0; i < attempts; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    const res = await fetch(`${baseUrl}/${apiPrefix}/cortes/${cutId}/estado`);
    const body = await res.json().catch(() => null);
    const status = body?.data?.status ?? `http_${res.status}`;
    console.log(`  estado[${i + 1}/${attempts}]: ${status}`);
    if (status === 'activated' || status === 'failed') {
      console.log(JSON.stringify(body, null, 2));
      return;
    }
  }
  console.log('  (se agotaron los intentos; consulta manual con GET /cortes/:cutId/estado)');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.file) {
    console.log(
      'Uso: send-test-cut.mjs --file <ruta.db3> [--cut-id ID] [--version V] ' +
        '[--activation-at now|+30s|ISO8601] [--invalid-token] [--bad-hash] ' +
        '[--bad-signature] [--corrupt-db] [--no-poll]',
    );
    process.exit(args.help ? 0 : 1);
  }

  const baseUrl = (args.baseUrl ?? process.env.BASE_URL ?? 'http://127.0.0.1:3000').replace(/\/$/, '');
  const apiPrefix = (process.env.API_PREFIX ?? 'api/v1').replace(/^\/|\/$/g, '');
  const hmacSecret = args.hmacSecret ?? process.env.CORTES_MANIFEST_HMAC_SECRET;
  const jwtSecret = args.jwtSecret ?? process.env.JWT_SECRET;
  const subject = args.subject ?? process.env.DIFUSOR_SUBJECT ?? 'difusor-simulado-local';
  const cutId = args.cutId ?? `corte-prueba-${Date.now()}`;
  const version = args.version;
  const activationAt = resolveActivationAt(args.activationAt);

  if (!hmacSecret) {
    throw new Error('Falta CORTES_MANIFEST_HMAC_SECRET (usa --hmac-secret o la variable de entorno)');
  }
  if (!jwtSecret) {
    throw new Error('Falta JWT_SECRET (usa --jwt-secret o la variable de entorno)');
  }

  let fileBuffer = readFileSync(args.file);
  if (args.corruptDb) {
    fileBuffer = Buffer.from('esto no es un sqlite valido — corte de prueba corrupto');
  }

  const realSha256 = createHash('sha256').update(fileBuffer).digest('hex');
  const sha256 = args.badHash ? '0'.repeat(64) : realSha256;

  const manifestCore = {
    cutId,
    version,
    activationAt,
    sha256,
    generatedAt: new Date().toISOString(),
    signatureAlgorithm: 'HMAC-SHA256',
  };
  const canonicalPayload = JSON.stringify(manifestCore);
  const validSignature = createHmac('sha256', hmacSecret)
    .update(canonicalPayload)
    .digest('hex');
  const signature = args.badSignature ? '0'.repeat(64) : validSignature;
  const manifest = JSON.stringify({ ...manifestCore, signature });

  const token = args.invalidToken
    ? 'token-invalido-de-prueba'
    : signHs256Jwt({ sub: subject, iat: Math.floor(Date.now() / 1000) }, jwtSecret);

  const form = new FormData();
  form.append('cutId', cutId);
  form.append('version', version);
  form.append('activationAt', activationAt);
  form.append('manifest', manifest);
  form.append('database', new Blob([fileBuffer]), 'corte.db3');

  const url = `${baseUrl}/${apiPrefix}/cortes`;
  console.log(`POST ${url}`);
  console.log(`  cutId=${cutId} version=${version} activationAt=${activationAt} sha256=${sha256.slice(0, 12)}...`);

  const response = await fetch(url, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  });

  const bodyText = await response.text();
  console.log(`<- ${response.status} ${response.statusText}`);
  console.log(bodyText);

  if (!args.noPoll && (response.status === 200 || response.status === 202)) {
    await pollStatus(baseUrl, apiPrefix, cutId);
  }

  process.exitCode = response.ok ? 0 : 1;
}

main().catch((error) => {
  console.error('Error:', error.message);
  process.exit(1);
});
