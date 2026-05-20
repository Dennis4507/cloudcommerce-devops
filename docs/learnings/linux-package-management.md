# Linux Package Management & GPG Keys — Deep Dive

## The apt Package Manager

`apt` (Advanced Package Tool) is the package manager for Debian-based Linux distributions including Ubuntu. It downloads, installs, updates, and removes software packages from curated repositories.

```bash
apt update              # refresh the list of available packages
apt install jenkins     # install a package
apt remove jenkins      # remove a package (keep config files)
apt purge jenkins       # remove package AND config files
```

Packages come from **repositories** — servers that host curated, verified software. Ubuntu ships with default repositories. For software not in Ubuntu's repos (like Jenkins), you add a third-party repository.

## What is a Repository?

A repository is a remote server hosting software packages. Adding a repository tells apt "also look here for packages when I install or update".

For Jenkins, the repository entry looks like:

```
deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/
```

Breaking this down:
- `deb` — binary packages (as opposed to `deb-src` for source code)
- `signed-by=...` — the GPG key file used to verify packages from this repo
- `https://pkg.jenkins.io/debian-stable` — the repository URL
- `binary/` — the component within the repo

## Why Packages Are Signed — GPG Keys

Anyone could set up a server that looks like a Jenkins repository and serve malicious packages. Without a way to verify authenticity, `apt install jenkins` could install anything.

**GPG (GNU Privacy Guard)** is a cryptographic tool that solves this. The process:

1. The software publisher (Jenkins team) creates a cryptographic key pair
2. They sign every package with their private key
3. They publish their public key so users can verify packages
4. When you run `apt install jenkins`, apt downloads the package and verifies the signature against the public key
5. If the signature doesn't match, apt refuses to install

This chain of trust means you can be confident that a package marked as Jenkins is actually built by the Jenkins team — not by an attacker who compromised a mirror or DNS.

## ASCII Armored (.asc) vs Binary (.gpg) Format

GPG keys come in two formats:

```
.asc  → ASCII armored (human-readable text, starts with "-----BEGIN PGP PUBLIC KEY BLOCK-----")
.gpg  → Binary (machine-readable, not human-readable)
```

The `signed-by=` field in modern apt sources **requires binary format**. Providing an ASCII-armored key causes apt to silently fail to trust the repository, resulting in:

```
NO_PUBKEY 7198F4B714ABFC68
E: The repository 'https://pkg.jenkins.io/debian-stable binary/ Release' is not signed.
```

**Converting from ASCII to binary — gpg --dearmor:**

```bash
curl -fsSL https://pkg.jenkins.io/jenkins.io.key | gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
```

`gpg --dearmor` reads ASCII armored input and outputs binary format. The `-o` flag writes the result to a file.

**Verifying what's in a key file:**

```bash
gpg --show-keys /usr/share/keyrings/jenkins-keyring.gpg
```

Output:
```
pub   rsa4096 2023-03-27 [SC] [expired: 2026-03-26]
      63667EE74BBA1F0A08A698725BA31D57EF5975CA
```

This shows the key fingerprint and expiry date. If the key shows `[expired]`, apt will reject packages signed with it — even if the format is correct.

## Keyservers — Fetching Keys by ID

A keyserver is a public database of GPG keys. Instead of downloading a key from a URL (which serves whatever the publisher last uploaded), you can fetch a specific key by its unique ID:

```bash
gpg --no-default-keyring \
    --keyring /usr/share/keyrings/jenkins-keyring.gpg \
    --keyserver keyserver.ubuntu.com \
    --recv-keys 7198F4B714ABFC68
```

Breaking this down:
- `--no-default-keyring` — don't use the user's personal keyring
- `--keyring` — write the key to this specific file
- `--keyserver` — which keyserver to query
- `--recv-keys` — the key ID to fetch (the last 16 hex characters of the fingerprint)

**Why keyserver IDs are more reliable than URLs:**
- A URL serves whatever file was last uploaded — which may be outdated or expired
- A key ID lookup always retrieves the current valid key for that ID
- The keyserver is updated when the publisher rotates keys
- If a key is revoked (marked invalid), the keyserver reflects that immediately

## The Jenkins Signing Key Rotation — A Real-World Case Study

Jenkins rotated their signing key in early 2026. This caused a common and confusing failure pattern for anyone following older documentation.

**The situation:**
- Jenkins' official documentation pointed to: `https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key`
- That URL served a key with fingerprint `5BA31D57EF5975CA`
- That key **expired on 2026-03-26**
- Jenkins began signing their packages with a new key: `7198F4B714ABFC68`
- The old URL continued to serve the expired key — it was never updated

**The symptom:** Running `apt-get update` after adding the Jenkins repository always failed with `NO_PUBKEY 7198F4B714ABFC68` — even after correctly downloading and dearmoring the key from the official URL.

**The diagnosis:**
```bash
gpg --show-keys /usr/share/keyrings/jenkins-keyring.gpg
# Output shows fingerprint 5BA31D57EF5975CA — NOT 7198F4B714ABFC68
# And [expired: 2026-03-26]
```

Two separate problems were present:
1. The format was wrong (ASCII instead of binary) — fixed by `--dearmor`
2. The key content was wrong (expired key from stale URL) — fixed by keyserver lookup

**The fix:**
```bash
gpg --no-default-keyring \
    --keyring /usr/share/keyrings/jenkins-keyring.gpg \
    --keyserver keyserver.ubuntu.com \
    --recv-keys 7198F4B714ABFC68
```

This fetched the current Jenkins signing key directly from the Ubuntu keyserver. `apt-get update` then succeeded immediately.

## systemd and Service Management

When packages like Jenkins are installed, they register as systemd services — meaning the OS manages starting, stopping, and restarting them automatically.

```bash
sudo systemctl start jenkins      # start the service now
sudo systemctl stop jenkins       # stop the service
sudo systemctl enable jenkins     # start automatically on every boot
sudo systemctl disable jenkins    # don't start on boot
sudo systemctl status jenkins     # check current status
sudo systemctl restart jenkins    # stop then start
```

**Reading systemctl status:**
```
● jenkins.service - Jenkins Continuous Integration Server
     Active: active (running)   ← this is what you want
```
or
```
     Active: failed (Result: exit-code)   ← something went wrong
```

`enabled` and `running` are separate states:
- `enabled` = will start on next boot
- `running` = currently started
- A service can be enabled (will start on boot) but currently stopped, or running but not enabled (won't survive a reboot)

## Debugging a Failed Service

When `systemctl status` shows `failed`, the status output alone rarely explains why. The diagnostic sequence:

**Step 1: Check the journal**
```bash
sudo journalctl -xeu jenkins.service --no-pager | tail -50
```

`-x` adds explanatory text, `-e` jumps to the end, `-u` filters by unit name.

**Step 2: Run the binary directly**

If journalctl only shows "process exited with error code" without a reason, bypass systemd entirely and run the executable directly:

```bash
sudo /usr/bin/jenkins
```

This surfaces the actual application error that systemd's wrapper was swallowing. In our case:
```
Running with Java 17 from /usr/lib/jvm/java-17-openjdk-amd64, which is older than
the minimum required version (Java 21).
```

Running the binary directly is often the fastest path to the root cause — systemd wraps errors in its own messages, but the application output is unfiltered.

## Interview Talking Points

- "I debug package signing failures by inspecting the actual key on disk with `gpg --show-keys` — this reveals whether the problem is the key format, the key content, or an expired key"
- "I fetch signing keys by ID from a keyserver rather than by URL — URLs serve whatever was last uploaded and can silently serve expired keys after a rotation"
- "When systemd shows a service failed without a clear reason, I run the binary directly to bypass systemd's error wrapping and get the application's actual output"
- "GPG key rotation is a common failure point in automated Jenkins installs — hardcoding a key URL in scripts will break silently when the publisher rotates"
- "The `.asc` vs `.gpg` distinction is a frequent source of confusion in Ubuntu 22.04+ Jenkins setups — modern apt requires binary dearmored keys in the `signed-by` field"
