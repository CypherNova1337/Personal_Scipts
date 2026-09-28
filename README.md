# Personal_Scripts

Small, focused security tools that don't warrant their own repo — plus an index
pointing at the dedicated tools that do the heavy lifting.

Most of my recon and exploitation workflow lives in purpose-built repos (see
[the toolbox](#the-toolbox) below). This repo deliberately holds only what those
don't already cover:

- **`exploit/webscan.py`** — async scanner for the HTTP-misconfiguration classes
  my other tools don't handle: **CORS**, **CRLF injection**, and **hop-by-hop
  header abuse**.
- **`recon/secretscan.py`** — entropy + rule-based secret detection for any set
  of files.
- **`core/`** — the shared async HTTP engine both are built on.

> **Authorized use only.** For assets you own or are explicitly permitted to test.

---

## webscan.py

VoidRecon's vuln phase already covers open-redirect, SSRF, SQLi, JWT, prototype
pollution and CVE matching. `webscan.py` fills the remaining gaps, on a real
async engine (pooling, bounded concurrency, token-bucket rate limiting, retries
with backoff):

```bash
pip install -r requirements.txt

# One check or all of them; targets as args, -i file, or stdin
./exploit/webscan.py cors -i live.txt -o cors.jsonl -c 100 --rate 200
./exploit/webscan.py hopbyhop -u https://target/app --cache-test
cat urls.txt | ./exploit/webscan.py all -q -o findings.jsonl
```

| check | detects |
|-------|---------|
| `cors` | reflected origin, `null`, prefix/suffix/subdomain bypass, unescaped-dot regex, wildcard + credentials |
| `crlf` | CRLF injection / HTTP response splitting (multi-encoding payloads) |
| `hopbyhop` | front ends that honor `Connection:` to strip headers, plus optional cache-poisoning check |

Findings print to the console and, with `-o`, as JSONL. Shared flags:
`-c/--concurrency`, `--rate`, `--timeout`, `--retries`, `-H`, `--proxy`, `-k`,
`--http2`, `--min-severity`, `-q`.

## secretscan.py

Two strategies combined to keep signal high: tuned regexes for known credential
formats (AWS, GCP, GitHub, Slack, Stripe, JWT, private keys…) plus Shannon-entropy
scoring to catch unknown high-randomness tokens, with a stop-list to suppress
noise.

```bash
./recon/secretscan.py -r ./some/dir            # recurse
./recon/secretscan.py app.js -o secrets.jsonl
cat bundle.js | ./recon/secretscan.py -
```

## core/

The async framework both tools share — reusable if you write another check:

- `engine.py` — pooled `httpx.AsyncClient`, concurrency semaphore, token-bucket
  rate limiter, retry/backoff (honors `Retry-After`), manual redirect-chain
  capture, normalized `Response`.
- `findings.py` — `Finding`/`Severity` model + colored console / JSONL reporter.
- `cli.py` — shared argparse, target loading (arg/file/stdin), engine build.

---

## The toolbox

For everything this repo intentionally leaves out, use the dedicated tools:

| Need | Tool |
|------|------|
| Full recon pipeline (subdomains → probe → crawl → vuln, 50 modules) | [VoidRecon](https://github.com/CypherNova1337/VoidRecon) |
| Apex-domain recon methodology | [DomainDive](https://github.com/CypherNova1337/DomainDive) · [WebRecon-Arsenal](https://github.com/CypherNova1337/WebRecon-Arsenal) |
| Subdomain permutation + resolve | [DNS-Helix](https://github.com/CypherNova1337/dns-helix) |
| Hidden HTTP parameter discovery | [paramvoid](https://github.com/CypherNova1337/paramvoid) |
| Adaptive, WAF-aware SQL injection | [SmartSQL](https://github.com/CypherNova1337/SmartSQL) |
| RCE / SSTI / injection / deserialization | [VoidStrike](https://github.com/CypherNova1337/VoidStrike) |
| IDOR / broken access control | [Auto-IDOR](https://github.com/CypherNova1337/Auto-IDOR) |
| Origin-IP discovery behind a CDN | [VoidOrigin](https://github.com/CypherNova1337/VoidOrigin) |
| In-page JS analysis (bookmarklet) | [Code-Specter](https://github.com/CypherNova1337/Code-Specter) |
| Sourcemap → original JS reconstruction | [sourcemapper](https://github.com/CypherNova1337/sourcemapper) |
| gf patterns (incl. secret/key patterns) | [GF_Patterns](https://github.com/CypherNova1337/GF_Patterns) |
| Nuclei templates | [Personal_Nuclei_Templates](https://github.com/CypherNova1337/Personal_Nuclei_Templates) · [Firebase_Nuclei](https://github.com/CypherNova1337/Firebase_Nuclei) |
| Wordlists | [VoidLexicon](https://github.com/CypherNova1337/VoidLexicon) |

## License

[MIT](LICENSE) © CypherNova
