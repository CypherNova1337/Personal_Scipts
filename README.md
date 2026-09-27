# Personal_Scripts

A personal collection of recon and exploitation scripts I use on real targets,
cleaned up and organized into a small, composable toolkit. Everything is built
to chain together: the output of one stage feeds the input of the next, and a
single `pipeline.sh` runs the whole recon chain end to end.

> **Authorized use only.** These tools are for security testing against assets
> you own or are explicitly permitted to test (bug bounty scope, signed
> engagement, lab). You are responsible for how you use them.

---

## Layout

```
.
├── pipeline.sh              # master chain: subenum → probe → urls → js → (nuclei)
├── lib/
│   └── common.sh            # shared helpers (logging, deps, domain parsing)
├── recon/
│   ├── subenum.sh           # subdomain aggregator (many sources, concurrent)
│   ├── probe.sh             # live HTTP(S) probing (httpx / httprobe)
│   ├── urlcollect.sh        # historical + crawled URLs (gau/wayback/katana/OTX)
│   ├── jsrecon.sh           # JS discovery → endpoints + secret heuristics
│   ├── portscan.sh          # naabu port discovery + optional nmap -sV
│   ├── alienvault.sh        # AlienVault OTX URL extraction
│   ├── wayback.sh           # Wayback URLs + interesting file extensions
│   ├── urlscan.py           # urlscan.io subdomains/URLs
│   ├── virustotal.sh        # VirusTotal undetected URLs / IP resolution
│   ├── gdork.py             # Google dork runner
│   └── bookmarklet-urlscraper.js  # in-browser URL/endpoint scraper
├── exploit/
│   ├── ssrf-header-fuzz.sh  # blind SSRF / open-redirect / host-header via OAST
│   ├── cors-scan.sh         # CORS misconfiguration scanner
│   ├── openredirect.sh      # open-redirect fuzzer (param + payload matrix)
│   ├── takeover.sh          # subdomain takeover (CNAME + fingerprint)
│   ├── xss-scan.sh          # reflected/DOM XSS via dalfox
│   ├── crlf-scan.sh         # CRLF injection / response splitting
│   ├── hopbyhop.py          # hop-by-hop header abuse (+ cache poisoning)
│   ├── autoghauri.sh        # batch SQLi testing with ghauri
│   ├── nuclei-scan.sh       # nuclei runner (repo templates + severity filter)
│   ├── paramfuzz.sh         # hidden parameter discovery (arjun/x8)
│   └── nuclei-templates/
│       └── 404-bypass.yaml  # comprehensive 404 bypass template
└── recon.env.example        # sample API-key config
```

---

## Setup

Most scripts degrade gracefully — a missing tool is skipped, not fatal — so
install what you need for the workflows you use.

**Go tools (ProjectDiscovery et al.):**
`subfinder`, `httpx`, `naabu`, `katana`, `nuclei`, `chaos`, `assetfinder`,
`amass`, `gau`, `waybackurls`, `dalfox`, `subzy`, `ghauri`

**System:** `curl`, `jq`, `dig` (bind-utils), and Python 3.

**Python helpers:**

```bash
pip install requests googlesearch-python arjun
```

**API keys** (never hardcoded — read from the environment or `~/.config/recon.env`):

```bash
cp recon.env.example ~/.config/recon.env
$EDITOR ~/.config/recon.env        # add VT_API_KEY, URLSCAN_API_KEY, etc.
```

Make everything executable:

```bash
chmod +x pipeline.sh recon/*.sh recon/*.py exploit/*.sh exploit/*.py
```

---

## Quick start

Run the full recon chain against a target:

```bash
./pipeline.sh example.com                 # recon only
./pipeline.sh -l scope.txt -o acme --scan # multi-target + nuclei at the end
./pipeline.sh example.com --crawl --scan  # add active crawl + scan
```

Or run stages individually:

```bash
# 1. Subdomains
./recon/subenum.sh -l scope.txt -o out

# 2. Live services
./recon/probe.sh -i out/all_subdomains.txt -o out/probe

# 3. URLs + JS
./recon/urlcollect.sh -l out/probe/live.txt -o out/urls
./recon/jsrecon.sh -i out/urls/all_urls.txt -o out/js

# 4. Targeted exploitation
./exploit/cors-scan.sh   -i out/probe/live.txt
./exploit/takeover.sh    -i out/all_subdomains.txt
./exploit/openredirect.sh -i out/urls/all_urls.txt
./exploit/xss-scan.sh    -i out/urls/all_urls.txt
./exploit/nuclei-scan.sh -i out/probe/live.txt
```

Most scripts accept `-h/--help`, a single target argument, or `-i/-l` for a
file (`-` for stdin), and write results into a per-tool output directory.

### Out-of-band (OAST) scripts

`ssrf-header-fuzz.sh` needs an interaction listener. Run
[`interactsh-client`](https://github.com/projectdiscovery/interactsh) in another
terminal, then:

```bash
export OAST_DOMAIN="youruniqueid.oast.fun"
./exploit/ssrf-header-fuzz.sh -l out/probe/live.txt
```

Watch the `interactsh-client` window for callbacks to `m1.* … m4.*`, each of
which maps to a specific injection vector.

### Bookmarklet

`recon/bookmarklet-urlscraper.js` has readable source plus a one-line
`javascript:` version at the bottom — paste that line as a browser bookmark's
URL and click it on any page to list discovered URLs and endpoints.

---

## Credits

Some scripts started from other people's work and were reworked here (env-based
keys, argument handling, shared library, bug fixes):

- `recon/gdork.py`, `recon/virustotal.sh`, `recon/urlscan.py` — based on
  scripts by **coffinxp** ([LostSec](https://github.com/coffinxp)).
- `exploit/nuclei-templates/404-bypass.yaml` — inspired by the ProjectDiscovery
  fuzzing templates and HackTricks 40x-bypass techniques.

Everything else is my own. Third-party tools invoked by these scripts
(ProjectDiscovery suite, ghauri, dalfox, arjun, subzy, tomnomnom's tools, etc.)
belong to their respective authors.

## License

[MIT](LICENSE) © CypherNova
