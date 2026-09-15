// Test-only scalars; never imported by product runtime.
import { createECDH } from 'node:crypto';
import { canonical, hash, generateIdentity, sign, sharedKey, seal, sealEnrollment } from '../BrowserClient/src/crypto.js';
function pair(n:number) { const e = createECDH('prime256v1'); const scalar = Buffer.alloc(32); scalar[31]=n; e.setPrivateKey(scalar); const pub=e.getPublicKey(); return { pub:pub.toString('base64'), jwk:{kty:'EC',crv:'P-256',d:scalar.toString('base64url'),x:pub.subarray(1,33).toString('base64url'),y:pub.subarray(33).toString('base64url'),ext:true} }; }
const host=pair(1), browser=pair(2), identity=await generateIdentity();
const fields=['challenge','fixture host','fixture browser','http://127.0.0.1:8788','view','synthetic','1','1'.repeat(64),'2000000000000','2'.repeat(64),'3'.repeat(64),host.pub];
const ch=await hash(canonical(fields));
const key=await crypto.subtle.importKey('jwk',host.jwk,{name:'ECDH',namedCurve:'P-256'},false,['deriveBits']);
const aes=await sharedKey(key,browser.pub,fields);
const offer={secret:"3".repeat(64),hostID:"4".repeat(64),url:"http://127.0.0.1:8791"};
const fixture={enrollment:{...offer,peerID:"5".repeat(64),publicKey:identity.publicKey,...await sealEnrollment(offer,"5".repeat(64),identity.publicKey)},notice:'TEST ONLY fixed private scalars; never use for live sessions',fields,hash:ch,signingPublic:identity.publicKey,signature:await sign(fields,identity.privateKey),hostScalar:Buffer.from([ ...Array(31).fill(0),1]).toString('base64'),hostPublic:host.pub,browserPublic:browser.pub,browserJWK:browser.jwk,session:'1'.repeat(64),envelope:await seal({kind:'ready'},aes,'1'.repeat(64),'host',1,ch)};
await Bun.write(new URL('../BrowserFixtures/crypto-vector.json',import.meta.url), JSON.stringify(fixture,null,2)+'\n');
