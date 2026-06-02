# Trivy and Container Security

## What is Trivy?

Trivy is an open-source vulnerability scanner for container images, maintained by Aqua Security. It scans the contents of a Docker image and checks every package, library, and binary against a database of known CVEs (Common Vulnerabilities and Exposures).

In this project, Trivy runs inside the Jenkins pipeline on every build — after the image is built but before it is pushed to ECR. This means vulnerabilities are caught before they ever reach the cluster.

```
Build → Trivy Scan → Push to ECR → ArgoCD Deploy
              ↑
              if CRITICAL found with --exit-code 1, pipeline stops here
```

---

## What Trivy Scans

For each Docker image, Trivy checks:

| Layer | What it checks | Example |
|-------|---------------|---------|
| OS packages | Alpine, Debian apt packages | libssl, glibc |
| Language runtime | Go stdlib, Python packages, Node modules | golang.org/x/net |
| Compiled binaries | Which library versions were linked at build time | go.sum fingerprints |
| Secrets | Hardcoded credentials, API keys (secret scanning) | AWS keys in source |

---

## CVE Severity Levels

Trivy uses a 4-level severity system:

| Level | Meaning | Action |
|-------|---------|--------|
| CRITICAL | Exploit likely, high impact (RCE, auth bypass) | Fix immediately |
| HIGH | Serious impact (DoS, data exposure) | Fix in next cycle |
| MEDIUM | Limited impact | Fix when possible |
| LOW | Minimal risk | Track, fix in bulk |

---

## The Two Types of Go Vulnerabilities

When scanning Go services, Trivy distinguishes between two completely different types of vulnerabilities:

### Type 1 — Go Standard Library

The Go language itself ships with a standard library — packages like `net`, `net/http`, `crypto` that your code imports. When bugs are found in these packages, they are fixed in a new Go release.

**Where the bug lives:** Inside the Docker build image (`golang:1.26.2-alpine`)

**How Trivy detects it:** The compiled binary contains version metadata. Trivy reads `go version` embedded in the binary and checks that version against the CVE database.

**How to fix:** Change the base image version in the Dockerfile:
```dockerfile
FROM golang:1.26.2-alpine  →  FROM golang:1.26.3-alpine
```
Rebuilding the image with the new Go version recompiles the binary against the patched stdlib. No code changes needed.

**Affects:** All services built with that Go version — in this project, frontend, checkoutservice, productcatalogservice, shippingservice all used Go 1.26.2.

---

### Type 2 — Go Module Dependencies

Go projects declare third-party dependencies in `go.mod` — a manifest file that lists every external package and its required version. When a bug is found in one of those packages, upgrading the version in `go.mod` is required.

**Where the bug lives:** In the third-party package code, compiled into the binary.

**How Trivy detects it:** Reads the module version information embedded in the Go binary and checks each module against the CVE database.

**How to fix:** Run `go get` to download the patched version and update both `go.mod` and `go.sum`:
```bash
go get google.golang.org/grpc@v1.79.3
go mod tidy
```

**Why go.sum matters:** `go.sum` stores cryptographic checksums (SHA-256 hashes) of every dependency. Go verifies these at build time. If `go.mod` is updated but `go.sum` is not, the build fails with a checksum mismatch error. This is intentional — it prevents supply chain attacks where a package is silently replaced. You cannot simply edit `go.mod`; you must run `go get` on a machine with Go installed so the real checksum can be calculated and written.

---

## The Two Types of Node.js Vulnerabilities

Node.js services declare dependencies in `package.json` with version constraints, and lock exact versions in `package-lock.json`.

**How to fix:**
```bash
npm update <package>       # update a specific package
npm update                 # update all packages within version constraints
npm audit fix              # automatically fix known vulnerabilities
npm audit fix --force      # fix including breaking changes (use carefully)
```

Commit both `package.json` and `package-lock.json` after updating.

**package-lock.json is the equivalent of go.sum** — it locks exact versions and checksums so every developer and CI/CD system gets identical packages.

---

## The Two Types of Python Vulnerabilities

Python services list dependencies in `requirements.txt`.

**How to fix:**
```bash
pip install --upgrade pyasn1==0.6.3    # upgrade specific package to known safe version
pip freeze > requirements.txt           # update the requirements file
```

Python has no lock file equivalent by default (unless using `pip-tools` or `poetry`). `requirements.txt` serves as both the manifest and the version pin.

---

## CVEs Found in This Project

### Go Standard Library — Fixed ✅

All 4 Go services were built with `golang:1.26.2-alpine`. Upgraded to `golang:1.26.3-alpine`.

| CVE | Severity | Component | Impact |
|-----|----------|-----------|--------|
| CVE-2026-33811 | HIGH | net | DoS via long CNAME DNS response |
| CVE-2026-33814 | HIGH | net/http (HTTP/2) | Infinite loop via crafted SETTINGS frame |
| CVE-2026-39820 | HIGH | net/mail | Crash via malformed email address |
| CVE-2026-39823 | HIGH | net/url | URL handling regression |
| CVE-2026-39825 | HIGH | net/http/httputil | ReverseProxy parameter leakage |
| CVE-2026-39826 | HIGH | html/template | XSS via script tag in trusted template |
| CVE-2026-39836 | HIGH | net | Panic via NUL byte in port lookup |
| CVE-2026-42499 | HIGH | net/mail | DoS via pathological phrase parser |

### Go Module Dependencies — Fixed ✅

`shippingservice` only. Other services already had patched versions.

| CVE | Severity | Library | Impact | Fix |
|-----|----------|---------|--------|-----|
| CVE-2026-33186 | CRITICAL | grpc v1.79.2 | Authorization bypass via HTTP/2 path validation | Upgrade to v1.79.3 |
| CVE-2026-29181 | HIGH | otel v1.39.0 | DoS via crafted multi-value baggage headers | Upgrade to v1.43.0 |

### Remaining Findings (documented, fix path known)

| Service | Language | Key Findings |
|---------|----------|-------------|
| paymentservice | Node.js | CRITICAL: protobufjs v6.11.4 (arbitrary code execution) → fix: `npm update protobufjs` |
| recommendationservice | Python | HIGH: pyasn1 v0.5.0 (DoS) → fix: `pip install pyasn1==0.6.3` |
| recommendationservice | Python | HIGH: urllib3 v2.6.3 (info disclosure, DoS) → fix: `pip install urllib3==2.7.0` |
| shoppingassistantservice | Python/Debian | Multiple findings in debian base image and Python packages |

---

## Pipeline Configuration

Trivy runs in the Jenkins pipeline with these flags:

```bash
trivy image \
  --exit-code 0 \          # report but don't fail the build (development mode)
  --severity HIGH,CRITICAL \ # only report HIGH and CRITICAL, ignore MEDIUM/LOW
  --no-progress \           # cleaner output in CI logs
  <image>:<tag>
```

**`--exit-code 0`** means the build always continues regardless of findings. In production the correct value is `--exit-code 1` — which would block the push to ECR if any CRITICAL vulnerability is found. The pipeline was designed this way intentionally during development so builds could complete while findings were being investigated. Once the remediation phase is complete, changing to `--exit-code 1` for CRITICAL severity enforces a hard security gate.

---

## Production Patterns

### Dependabot / Renovate

In real teams, nobody runs `go get` or `npm update` manually. Dependabot (GitHub) or Renovate automatically opens pull requests every week with updated dependency files:

```
Dependabot opens PR:
  go.mod:  grpc v1.79.2 → v1.79.3
  go.sum:  [updated checksums]
  
  Title: "bump grpc from 1.79.2 to 1.79.3"
  Body: "Fixes CVE-2026-33186 (CRITICAL)"
```

Engineers review and merge. CI runs the full pipeline. If Trivy passes, the PR merges automatically.

### Admission Controllers

In production Kubernetes, an OPA (Open Policy Agent) or Kyverno policy can block deployment of images with CRITICAL CVEs:

```yaml
# Block any image that failed Trivy scan
policy: deny if trivy_critical_count > 0
```

This makes the security gate cluster-level, not just pipeline-level. Even if someone bypasses Jenkins, the cluster refuses to run vulnerable images.

### Image Signing (Cosign)

After Trivy passes, images can be signed with Cosign (Sigstore). The cluster then only runs signed images — proving they passed the security scan and came from your pipeline, not from a compromised registry.

---

## Key Takeaways

1. **Your code is not the only attack surface.** Every package you depend on, and every package those packages depend on, is part of your attack surface. Trivy scans the whole tree.

2. **Base image vulnerabilities are not your fault but are your responsibility.** The bugs in Go 1.26.2 were written by the Go team, not you. But you chose to build with that version, so you are responsible for upgrading when a fix is available.

3. **go.sum exists to prevent supply chain attacks.** You cannot update a dependency version without running the actual download. This is a feature. It prevents an attacker from replacing a package with malicious code between your machine and the build server.

4. **Different ecosystems, same pattern.** Go uses go.mod + go.sum. Node.js uses package.json + package-lock.json. Python uses requirements.txt. The concept is identical: a manifest (what you want) and a lockfile (the exact verified version you got). Fixing vulnerabilities always means updating both.

5. **Pipeline scanning is not optional.** These CVEs were present in Google's own Online Boutique demo application. Without Trivy in the pipeline, they would never have been found. Automated scanning catches what code review and testing cannot.
