# Legality & intended use

**Not legal advice.** This note records how *metal-mirage* is intended to be used and summarizes publicly available legal context the maintainer considered. Laws change; your country, employer, and cloud contract may differ. If you need a determination for your situation, talk to a lawyer.

## Intended use (this repo)

metal-mirage is **personal / self-host infrastructure**:

- Bring up a Talos (or bare-metal) Kubernetes lab on Azure (or your own machines)
- Optional DR (Traffic Manager + witness + cold standby)
- Optional **personal** WireGuard exit VM(s) for your own devices
- Optional Clerk + Neon peer-minting demo for *your* peers — not a paid multi-tenant VPN product

It is **Apache-2.0** open source (`LICENSE`). Publishing the code and running it for yourself is the design center. It is **not** marketed as a commercial VPN, streaming unblocker, or “bypass geo-blocks” service — those product surfaces stay out of this repo ([ROADMAP.md](ROADMAP.md)).

## Short answer for personal use

**Yes — personal self-host use is the lowest-risk framing for this project**, in jurisdictions where civilian VPNs are legal (including the United States for ordinary privacy / remote-access use).

| Activity | Typical posture (US-centric research) |
|----------|----------------------------------------|
| Run Talos/K8s/Flux lab for yourself | Ordinary cloud / home-lab use |
| Run WireGuard on a VM you control for **your** laptop/phone | Widely treated as lawful privacy / remote-access tooling |
| Publish this IaC under Apache-2.0 | Dual-use OSS; legality turns on *use and marketing*, not the protocol |
| Use the tunnel to commit crimes (fraud, unauthorized access, etc.) | Still illegal — a VPN does not legalize the underlying act |
| Sell multi-tenant exits / market “unblock Netflix / dodge geo rights” | Different product; higher ToS / inducement / regulatory risk — **out of scope here** |

A VPN changes where traffic appears to exit. It does **not** put you above copyright, computer-crime, sanctions, or platform contract rules.

## What this repo ships (legally relevant)

| Component | Notes |
|-----------|--------|
| Pulumi Go + Azure / Talos / Flux | Standard infrastructure-as-code |
| `infra/vpn-gateways` + cloud-init WireGuard | Orchestrates a stock WireGuard userspace/kernel stack; does not invent a new cipher suite |
| `scripts/vpn-bootstrap.sh`, `vpn-reconcile-peers.sh` | Operator tools to mint/sync **your** peers |
| `control-plane/` | Optional demo API (Clerk + Neon); not billing or App Store clients |
| Witness / Traffic Manager | Portfolio-style DR for **your** app path — DNS TTL honesty applies |

WireGuard itself is widely deployed open-source VPN software. This repo is closer to “Terraform your own exit” than to operating a NordVPN-class service.

## Risk areas (ranked for this project)

### 1. What you do *through* the tunnel (always yours)

Illegal activity remains illegal with or without WireGuard. Keep exits locked to peers you trust (`vpn-bootstrap` / reconcile). Do not run open signup on your Azure public IP without abuse controls — that is how personal labs become someone else’s crime scene.

### 2. Marketing / inducement (avoided in-repo)

US secondary copyright liability discussions often turn on **inducement** or a service **tailored for infringement** (see e.g. the Supreme Court’s framing in *Cox Communications v. Sony Music Entertainment*, 2026). DMCA anti-circumvention (17 U.S.C. § 1201) targets bypassing *technological protection measures*; whether a plain IP geo-check counts is contested and fact-specific.  

**Practical rule for this repo:** document privacy, remote access, and lab DR. Do **not** add “bypass geo-blocks / unblock streaming” marketing or features whose primary story is rights evasion ([ROADMAP.md](ROADMAP.md) “Later — commercial”).

### 3. Operating exits for strangers (out of personal-use scope)

Publishing IaC ≠ running a VPN company. If you later host exits for paying third parties you take on:

- Cloud Acceptable Use Policy / possible suspension for unlawful or abusive traffic
- Abuse desk / LEA process / logging policy choices
- Possible local licensing or registration rules in some countries

Keep personal peers = personal use. Multi-tenant SaaS stays in a separate commercial codebase if ever pursued.

### 4. Cloud provider terms (Azure)

Microsoft’s Azure subscription / Online Services terms require lawful use and forbid using the service for unlawful, harmful, or AUP-violating activity. Personal WireGuard-on-a-VM is a common pattern; **reselling** Azure as a stealth commercial VPN fleet or allowing open abuse is where contracts get sharp. You are responsible for traffic leaving VMs on your subscription. Read the current [Azure subscription agreement](https://azure.microsoft.com/en-us/support/legal/subscription-agreement) and Acceptable Use Policy before long-lived production use.

### 5. Export controls (US EAR / encryption) — awareness

Encryption items can fall under the U.S. Export Administration Regulations (EAR), Category 5 Part 2. **Publicly available** encryption source code has a special path under 15 C.F.R. § 742.15(b). After the Wassenaar 2019-related updates, email notification to BIS/NSA for publicly available encryption source code generally remains for **“non-standard cryptography”** (see current § 742.15(b)(2); BIS summary of ENC changes).

This repository primarily **orchestrates** WireGuard (standard primitives) rather than shipping a novel cryptosystem. That usually keeps the compliance burden low, but:

- EAR analysis is fact-specific
- If you add custom crypto or redistribute encryption binaries in unusual ways, re-check
- Counsel can confirm whether any notice (`crypt@bis.doc.gov` / ENC coordinator) is warranted for *your* publication facts

Official starting points: [BIS encryption controls](https://www.bis.gov/learn-support/encryption-controls), [15 C.F.R. § 742.15](https://www.law.cornell.edu/cfr/text/15/742.15).

### 6. Other countries

Civilian VPN use is legal in much of the world and restricted or heavily regulated in a smaller set (examples often cited include China, Russia, Iran, and a few others — rules change). If you travel or place exits in another country, check **local** law for *use* and *operation* of VPN servers. Do not assume a US-centric answer applies everywhere.

### 7. EU copyright / geo-blocking (context only)

CJEU judgment **C-788/24** (*Anne Frank Fonds*, 9 July 2026) treated VPN (and similar) services as lawful technical tools and held that, where geo-blocking is ineffective, “communication to the public” is attributable to the **publisher** of the work, not the VPN provider. That is favorable background for VPN *infrastructure*; it is not permission to market piracy aids, and it is EU copyright framing — not a global safe harbor for every use.

## Personal-use operator checklist

| Do | Don’t |
|----|--------|
| Use exits for your own devices / household | Open peer signup to the internet |
| Set `adminCidr` to your `/32` before real use | Leave SSH/`9100` on `0.0.0.0/0` longer than a demo |
| Destroy idle Azure when not needed ([COST.md](COST.md)) | Assume “lab” means “unattended forever” |
| Keep Clerk/Neon keys and kubeconfigs out of git | Commit `.env`, `vpn-clients/`, `*.key` |
| Stay honest in docs (DNS TTL DR, not L4 magic) | Market this repo as a commercial unblocker |

## License disclaimer (already in `LICENSE`)

Software is provided **AS IS**, without warranty. Contributors are not liable for damages arising from use, to the extent Apache-2.0 allows. That license text does not replace local criminal or civil law.

## If you fork or commercialize

1. Keep or strengthen lawful-use language.
2. Do not imply endorsement of copyright circumvention or sanctions evasion.
3. For a paid multi-tenant product: separate ToS, AUP, abuse process, and counsel — outside this OSS boundary.
4. Re-read Azure (or other cloud) terms for hosting third-party traffic.

## References (non-exhaustive)

- Apache License 2.0 — repo `LICENSE`
- U.S. EAR encryption — [15 C.F.R. § 742.15](https://www.law.cornell.edu/cfr/text/15/742.15); [BIS encryption controls](https://www.bis.gov/learn-support/encryption-controls)
- Azure — [Online Subscription Agreement](https://azure.microsoft.com/en-us/support/legal/subscription-agreement)
- CJEU C-788/24 — [EUR-Lex](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=celex%3A62024CJ0788) (VPN / geo-blocking attribution)
- *Cox Communications, Inc. v. Sony Music Entertainment*, 607 U.S. ___ (2026) — contributory liability / inducement framing for service providers
- In-repo boundary — [ROADMAP.md](ROADMAP.md), [VPN.md](VPN.md), README honesty notes

## Document history

| Date | Note |
|------|------|
| 2026-08-09 | Initial research note: personal/self-host intent; US VPN legality; EAR awareness; Azure AUP; EU C-788/24; inducement caution |
