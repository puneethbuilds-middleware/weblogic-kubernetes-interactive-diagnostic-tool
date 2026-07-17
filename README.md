# WKID - WebLogic Kubernetes Interactive Diagnostic Tool

WKID is a read-only diagnostic collection script for WebLogic Server
domains running with the WebLogic Kubernetes Operator.

WKID is intended for interactive troubleshooting and for collecting a consolidated WebLogic Kubernetes diagnostic archive.

Current release candidate: `v4.20`.

## Current production release

WKID version and release information will be available from this repository's
GitHub releases page after publishing.

## Documentation

This README contains the primary usage documentation for WKID. Additional
examples and troubleshooting notes can be added under repository documentation
when the project is published.

## About

WKID helps collect diagnostics for WebLogic Kubernetes environments, including:

- WebLogic Domain status, conditions, and generation freshness
- Domain home source type: `Image`, `PersistentVolume`, or `FromModel`
- WebLogic Kubernetes Operator and webhook health
- Domain Cluster resources
- Introspector jobs, pods, logs, and ConfigMap metadata
- WebLogic pods, pod descriptions, events, and logs
- Services, Endpoints, Ingress, Network Policies, and storage
- Resource requests, limits, and metrics when metrics-server is available
- Optional Java process listings, OPatch inventory, thread dumps, JFR, WLST, and pod shell access

The recommended workflow is to run option `1`, which creates a consolidated diagnostic archive for review or analysis.

## Safety

WKID is designed as a read-only diagnostic collector for Kubernetes resources.
It does not run `kubectl apply`, `patch`, `edit`, `delete`, `scale`, rollout
restarts, port-forwarding, package installs, service restarts, or `kill`.

The only local filesystem changes are the diagnostic report folder, saved output
files, `000_manifest.txt`, and the optional `.zip` or `.tar.gz` archive. The
menu, saved files, manifest, and exit summary repeat this safety boundary.

Each menu option previews representative read-only command patterns before
collection starts.

Interactive pod shell, WLST, JFR, and thread dump collection are explicit
advanced choices. JFR starts a short Java Flight Recorder recording in the
selected JVM and downloads the resulting `.jfr` file. Thread dump collection
uses `jcmd Thread.print` or `jstack` and does not use `kill -3`.

## Quick Start

```bash
chmod +x wkid.sh
./wkid.sh
```

Select the namespace, select the WebLogic Domain resource, and choose:

```text
1) Generate diagnostic archive (Recommended)
```

At completion, WKID prints the generated archive and report folder locations.
Use the generated archive with your preferred diagnostic review workflow. If archive creation was not possible, use the full report folder.

If you select the WebLogic Operator namespace and it does not contain Domain
resources, WKID can ask you to choose a visible managed WebLogic Domain so the
recommended diagnostic archive includes both operator/webhook diagnostics and the
domain, introspector, pod, service, event, and log diagnostics needed for RCA.
If no Domain resources are visible to your Kubernetes user, WKID falls back to
operator/webhook diagnostics only and explains that a complete introspection RCA archive requires access to the WebLogic Domain namespace too.

## Usage

```bash
./wkid.sh [options]
```

Options:

```text
--output-dir DIR      Parent directory for saved output. Default: ./wko_diagnostic_reports
--log-tail N          Log lines to show for log operations. Default: 200
--event-limit N       Event rows to show for event operations. Default: 50
--no-color            Disable terminal colors.
--plain               Alias for --no-color.
--help                Show help.
```

Examples:

```bash
./wkid.sh
./wkid.sh --log-tail 500
./wkid.sh --output-dir /tmp/wko-diagnostics
./wkid.sh --no-color
```

## Requirements

- Bash
- `kubectl` configured for the target Kubernetes cluster
- Standard Linux shell tools: `awk`, `basename`, `cat`, `cut`, `date`, `grep`,
  `mkdir`, `pwd`, `sed`, `sh`, `sleep`, `sort`, `tail`, `tr`
- Optional: `jq` for richer JSON summaries
- Optional: `zip` or `tar` to create a diagnostic archive

WKID is written for Bash and standard Linux userland tools commonly available on
RHEL, Rocky Linux, AlmaLinux, Ubuntu, and similar distributions.
It avoids distro-specific package managers, service managers, init systems, and
host file paths.

Container-side actions such as Java process listing, OPatch, JFR, thread dumps,
and WLST depend on tools available inside the selected WebLogic container. If a
container image does not include a required tool, WKID reports that gracefully.

## Kubernetes Access

WKID uses the current `kubectl` context and requires read access to the selected
Domain namespace.

For complete diagnostic archives, the caller should be able to `get`, `list`, and `describe`
Domains, Clusters, pods, jobs, configmaps, services, EndpointSlices/endpoints,
events, PVCs/PVs/storage classes, and operator/webhook resources.

Pod logs and JVM actions require `pods/log` and `pods/exec` permissions.
Missing RBAC is reported in the captured output.

## Diagnostic Archive

The standard diagnostic archive prioritizes:

- Domain conditions and generation freshness
- Domain home source summary
- Exact pod image identity, image IDs, restart counts, and pod YAML
- Cluster resource diagnostics
- Introspector diagnostics, job YAML, current/previous pod logs, job logs, `/aux/models` model text files, archive listings, and available WDT temporary files
- Model ConfigMaps referenced by the Domain, with a note that ConfigMaps may contain environment configuration
- WKO-created events
- Operator and webhook health, current logs, and previous container logs when available
- WebLogic pods, descriptions, current logs, and previous container logs when available
- Services, Endpoints, Ingress, Network Policies, and storage
- WebLogic log-home summary
- Java process listings
- OPatch `lspatches` output from WebLogic pods when OPatch is present

The diagnostic archive asks before collecting heavier JVM artifacts. Archive defaults:
thread dumps are `5` dumps at `5` second intervals, and JFR duration is `15`
seconds.

WKID tracks both the Domain resource name and `spec.domainUID`. Pod, event, and
log selectors use the Domain UID, so the script still works when the Kubernetes
Domain resource name differs from the WebLogic Domain UID.

## Interactive Troubleshooting

In addition to the standard diagnostic archive, WKID provides individual interactive
collection options for live troubleshooting sessions:

- WKO Domain, Cluster, and introspector status
- Kubernetes cluster overview
- WebLogic server pod status
- Pod CPU/Memory requests, limits, and usage
- Readiness/liveness probe summary
- Services, Endpoints, Ingress, and Network Policies
- Persistent storage summary (PVCs, PVs, StorageClasses)
- Events
- WebLogic server pod descriptions
- WebLogic server pod logs
- WebLogic Operator / webhook pod logs
- List Java processes
- List OPatch inventory
- JFR
- Thread dumps
- Advanced interactive pod shell access
- Advanced interactive WLST session

For log operations, the screen displays only the last configured lines, default
`200`. If you choose to save, WKID fetches and saves the complete logs, not just
the displayed tail.

## Validation

Before publishing or after local edits, validate the script syntax:

```bash
bash -n ./wkid.sh
./wkid.sh --help
```

## Security

Do not include credentials, private keys, or unrelated sensitive files in diagnostic archive sharing. WKID redacts common password, token, secret, API key, access
key, private key, and bearer token patterns from saved text output, but users
should still review generated diagnostic archives before sharing them externally.

## Contributing

Contributions should keep WKID production-safe, read-only by default, and focused
on diagnostics that are useful for WebLogic Kubernetes troubleshooting.

## License

Copyright (c) 2026 Puneeth Prakash.

Choose a license before publishing this repository.
