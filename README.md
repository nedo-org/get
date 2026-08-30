# get.nedo — the installer for nedo

**This repository holds two things and nothing else: the bootstrap script people run, and
the release artifacts it downloads.** nedo itself lives elsewhere; this exists so that
installing it needs no credentials of ours.

```bash
curl -fsSL https://raw.githubusercontent.com/nedo-org/get/main/install.sh | bash -s -- 0.1.0-rc1
```

That fetches the payload for a version, verifies it against a published checksum, unpacks
it under `~/.nedo/versions/<version>` with a pinned `helm` beside it, and hands over to
the installer inside. It writes nothing outside `~/.nedo`. Run with no configuration
present, it copies a reference config next to where yours should go and stops, having
installed nothing.

## What nedo is

A branch-environment platform on a single Kubernetes node: push a branch to a project's
repository and it is deployed at `<branch>-<hash>.<your-domain>`, with its own database,
its own environment variables and its own logs. Git, CI and the container registry are
in-cluster; the only thing it needs from outside is a domain and a machine.

## What it needs before you start

- **A machine** you have `ssh` and passwordless `sudo` on. It is not a small stack:
  8 GB and 4 CPUs is the floor, plus disk for images.
- **A domain in Cloudflare.** Not optional and not cosmetic: the in-cluster registry gets
  a publicly trusted certificate through a DNS-01 challenge, so the installer needs an API
  token for a zone you actually control. A name nobody owns cannot be proved.
- **On your own machine:** `kubectl`, `jq`, `curl`, `ssh`, `openssl`. Not `helm` — the
  bootstrap fetches the pinned one itself, because a mismatched major is a difference that
  shows up much later as an upgrade behaving oddly.

## Status

`0.1.0-rc1` is a **pre-release**, and the honest description is: the platform it installs
has been run and re-run from scratch, but this packaged path has not yet been exercised
end to end by anybody other than its authors. Treat it as something to try on a machine
you are willing to wipe.

## Versions

Every release publishes three things that carry the same version — the platform's charts
as OCI artifacts, nedo's image, and the payload here. Naming a version pins all three.
`latest` resolves to the most recent **stable** release - GitHub's own definition, which
excludes pre-releases. So while only release candidates exist, `latest` finds nothing and
says so: name a version explicitly.
