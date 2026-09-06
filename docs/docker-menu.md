# Docker suite contract

This document freezes the public Docker interface and defines its daemon
context, record, stream, Compose, registry, and destructive-action boundaries.
The repository-wide contracts in `development.md`, `menu-spec.md`, and
`headers.md` take precedence.

## Public surface

| Command | Grammar |
| --- | --- |
| `docker-containers` | `[--action list]` or `--action exec\|logs\|start\|stop\|remove --id FULL_ID [action flags]` |
| `docker-images` | `[--action list]` or `--action run\|remove --id sha256:FULL_ID [action flags]` |
| `docker-clean` | no arguments, or `--scope SCOPE [--dry-run] [--yes] [--allow-remote]` |
| `docker-login` | `[REGISTRY\|--registry REGISTRY] [--username USER] [--password-stdin]` |
| `docker-compose-up` | `[--file FILE] [--dry-run] [--yes] [--allow-remote]` |
| `docker-compose-down` | `[--file FILE] [--dry-run] [--yes] [--allow-remote]` |
| `docker-compose-restart` | `[--file FILE] [--dry-run] [--yes] [--allow-remote]` |
| `docker-compose-logs` | `[--file FILE] [--tail 1..10000] [--follow]` |

`docker-menu COMMAND ...` is the canonical direct router and forwards every
argument unchanged. An unknown option or command returns `2`. With no
arguments, `docker-menu`, `docker-containers`, `docker-images`, and
`docker-clean` open their respective foreground picker. Esc is a successful
cancellation. Flags that have no effect for the selected action are rejected
instead of silently ignored.

Container `list` emits:

```text
id|name|state|image|ports
```

Image `list` emits:

```text
id|repository|tag|size|created
```

Container IDs are complete 64-character lowercase hexadecimal IDs. Image IDs
are complete `sha256:` identifiers. Formatted display rows never become
mutation targets.

## Context and daemon identity

Every daemon workflow freezes six fields before discovery:

```text
selector-mode, selector, endpoint, daemon-id, server-version, locality
```

`DOCKER_CONTEXT` takes precedence, followed by `DOCKER_HOST`, then the active
Docker context. Every invocation pins the validated client directory first
with `docker --config ...`, then uses `docker --context ...` or
`docker --host ...`; it does not silently return to ambient routing even when
the corresponding shell parameter was not exported. Context, endpoint, daemon
identity, and server version are re-read after authorization. A difference
fails closed. Context names cannot begin with an option and use a bounded
alphanumeric, dot, underscore, plus, and hyphen grammar.

The effective Docker config path must be canonical and strictly below
canonical `HOME`. An existing directory must be owned and mode `700`. A
missing leaf is accepted for daemon reads only when its canonical parent is
owned and not group/other writable; read-only workflows do not create it. If
`config.json` exists, it must be an owned, singly linked, non-symlink regular
file of mode `600` and at most 1 MiB. It must also parse through `jq` as
exactly one JSON object; empty input, arrays, scalars, trailing data, and
multiple top-level values are refused. A bounded Docker client probe must then
accept the file without emitting a parse warning. This matters because the
Docker client can otherwise warn and continue with default configuration.
Malformed configuration fails before daemon access, Compose actions, or
credential mutation, and neither parser diagnostics nor file content are
displayed. These checks apply to daemon, Compose, and registry operations
alike.

Unix sockets and Windows named pipes are local. Other endpoints are remote.
Read-only inventory and logs may inspect a remote endpoint, but mutation or
container/image execution requires explicit `--allow-remote`. That flag
bypasses only the locality gate, never target validation or confirmation.

Daemon, context, inventory, inspect, and resolved-Compose probes are
deadline-bound; the suite fails closed unless `timeout` or `gtimeout` is
available. A process that ignores the deadline signal is killed after a further
two-second grace interval. Output is capped before shell materialization.
Diagnostic capture keeps stderr separate from stdout and preserves interrupted
probe statuses. A daemon failure is distinct from an empty inventory.

## Interactive records

The suite owns its `fzf` behavior and consumes only the optional core color
theme. Every picker runs synchronously in the terminal foreground. Selection
stdout is captured in an invocation-owned mode-`600` file below a mode-`700`
directory in a validated temporary root. File identity, owner, link count, and
mode are checked before any chmod, removal, capture, or cleanup. The canonical
path must be a pattern-matching direct child of its validated parent. A
non-zero picker status carrying selection data is rejected.

Top-level selections must equal one complete menu row. Container and image
pickers carry only a snapshot-local numeric index, validate the complete row,
then recover the opaque full identifier from the private record array.
Automatic previews never render container logs, image history, environment
variables, or arbitrary daemon metadata.

The command menu uses the compact presentation in [`menu-spec.md`](menu-spec.md):
Docker context appears above the keyboard legend, and `Ctrl-/` toggles the
four-line command details below the list. Compose logs precede project changes;
resource cleanup remains last. Resource browsers retain their own layouts.

## Container and image actions

Container start and stop show the exact context, full ID, name, state, and
image, and both support `--dry-run`. Removal also supports `--dry-run` and
requires a terminal confirmation or `--yes`. Active containers are refused
unless `--force` is also explicit. The selected record and daemon context are
revalidated immediately before execution. Logs write Docker data to stdout and
`--follow` is explicit. Interactive exec requires terminal stdin and stdout,
and preserves the container session on stdout.

Image run and removal both show all known repository tags, full content ID,
size, platform, context, and resolved action. They support `--dry-run` and
require confirmation or `--yes`. Removal does not force by default; `--force`
is separate. The complete image identity and context are revalidated after
authorization. Running an image remains execution of image-defined code and
requires terminal stdin and stdout; the interactive session remains on stdout.

## Exact cleanup

`docker-clean` accepts these scopes:

- `stopped-containers`;
- `dangling-images`;
- `unused-networks`;
- `unused-volumes`; and
- `all`, which deliberately excludes every volume.

Cleanup never invokes a Docker `prune` command. It builds a typed, bounded set
of exact full IDs or volume names, displays the complete plan, and supports
side-effect-free `--dry-run`. Mutation requires a terminal confirmation or
`--yes`. The complete batch is recomputed once after authorization, then each
resource receives a narrow identity and eligibility check immediately before
an explicit `container rm`, `image rm`, `network rm`, or `volume rm`.
Resources that become eligible after review are not included. Batch membership
is compared as individual exact records, including plans with multiple targets.
Operations continue after an ordinary individual failure, report passed and
failed counts, and return non-zero for a partial result. An interruption
(`130` or `143`) during revalidation or removal stops the batch immediately,
preserves that status, and reports completed, failed, interrupted, and remaining
unattempted targets. Inspect the interrupted target before retrying: Docker may
have accepted its operation before the client stopped.

Volume cleanup is never implied by another scope. A volume remains a
high-value data object even when Docker reports it unused. A reviewed volume
record exposes only its name, driver, creation time, and a SHA-256 identity
digest. That digest also freezes the bounded scope, labels, options, and
mountpoint returned by Docker without displaying those potentially sensitive
fields. Empty required identity fields fail closed, so deleting and recreating
a same-name volume cannot satisfy revalidation.

## Compose boundary

Compose actions accept one owned, singly linked, non-symlink YAML descriptor
directly below the canonical current directory, with no group/other write bit
and a maximum size of 2 MiB. The workspace leaf must also be owned and not
group/other writable; each ancestor must be an unwritable user/root directory
or a root-owned sticky directory such as `/tmp`. Multiple default descriptors
are ambiguous and require `--file`.

Every non-empty ambient `COMPOSE_*` parameter and
`DOCKER_DEFAULT_PLATFORM` is refused. All present `COMPOSE_*` parameters and
`DOCKER_DEFAULT_PLATFORM` are removed from the environment of every Compose
plugin, configuration, log, and action invocation as a second boundary. This
covers current variables such as `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`,
`COMPOSE_PROFILES`, `COMPOSE_ENV_FILES`, `COMPOSE_REMOVE_ORPHANS`,
`COMPOSE_CONVERT_WINDOWS_PATHS`, `COMPOSE_PATH_SEPARATOR`, and `COMPOSE_BAKE`
without relying on a version-specific allowlist.

The suite fingerprints descriptor metadata and SHA-256 content. It also
resolves `docker compose -f FILE config`, caps that output at 2 MiB, and freezes
its SHA-256 digest so changes through interpolation or included configuration
fail revalidation. Every invocation pins `-f FILE`; mutation shows the exact
workspace, descriptor, config digest, context, and action before confirmation.
Compose project files and referenced images/build inputs remain executable
project-code trust boundaries.

The resolved-configuration digest does not freeze Dockerfiles, build contexts,
or files referenced through `env_file`. Another Compose client can also mutate
the same external project between the final check and Docker's operation.

Compose logs default to 100 lines and write only logs to stdout. Following is
explicit. `up`, `down`, and `restart` route Docker output to stderr and
preserve its exit status.

## Registry and streams

`docker-login` depends on the Docker client, `jq`, and `timeout` or `gtimeout`
for post-write validation, but not on a reachable daemon. These capabilities
are checked before Docker receives credentials, including when `config.json`
does not exist yet. Registry values cannot begin with an option and are
restricted to a bounded DNS/IPv4-hostname and optional port grammar.
Interactive login requires stdin and stderr terminals. Password bytes pass
directly from stdin to Docker only when `--password-stdin` and `--username`
are both explicit. The effective credential configuration directory is
displayed, but it must use the same private directory and file boundary
described above. ZDX never reads, stores, previews, or logs the credential.
The invocation pins that reviewed directory with Docker's global `--config`
option even when the shell variable was not exported. Login creates a missing
leaf atomically with mode `700` only after validating its parent, and then
revalidates Docker's resulting credential state, including JSON and Docker
client parsing.

Help, headings, context, plans, prompts, warnings, success, errors, and
non-interactive mutation-tool output use stderr. Structured inventories,
explicit log commands, and terminal exec/run sessions are Docker stdout
contracts. UI color honors `NO_COLOR`, `TERM=dumb`, and non-terminal stderr.

## Limits and residual boundaries

- picker and inventory payload: at most 1 MiB;
- records per inventory or cleanup plan: at most 2,048;
- individual image identity: at most 16 KiB;
- individual volume identity: at most 64 KiB, exposed only by digest;
- Docker `config.json`: at most 1 MiB;
- captured Docker config parser diagnostics: at most 8 KiB and never displayed;
- Compose descriptor and resolved configuration: at most 2 MiB each;
- logs tail: 1 through 10,000 lines;
- normal daemon probes: 5-10 seconds plus a two-second forced-kill grace,
  enforced by `timeout` or `gtimeout`.

Docker socket access can be equivalent to host administrator authority.
Portable userspace checks cannot eliminate the final same-user race after the
last context or object comparison. Docker also retains authority over the
atomicity and semantics of each requested resource operation. Real remote
contexts, Docker Desktop, rootless Docker, Podman compatibility, and
cross-platform Compose behavior remain manual acceptance boundaries.
