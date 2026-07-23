# gr4-dev

`gr4-dev` is a local multi-repo development workspace for GNU Radio 4 related
projects.

It provides monorepo-like developer ergonomics: bootstrap, shared environment
wiring, build/install helpers, and Docker image workflows, while keeping each
project in its own repository under `src/`.

This is not a dependency management system. It is a quick development workspace
setup.

## What this repo owns

- Workspace bootstrap and repo orchestration
- Shared local environment wiring
- Shared install directory (`install/`)
- Build and runtime convenience scripts
- Integration-oriented docs and defaults

This repo does not own or merge application source trees.

It also carries Docker image definitions under `images/` for dependency
images, toolchain baselines, and production runtime images.

## Quick start

1. Create a local env file and edit it to match your environment.

```bash
cp .env.example .env
```

2. Bootstrap repos from `repos.yaml`.

```bash
./bootstrap.sh
```

3. Validate workspace state.

```bash
./scripts/doctor.sh
```

4. Load the environment in your shell. Do this each time a new shell is opened.

```bash
source scripts/dev-env.sh
```

5. Build and install all known repos in default order into the local prefix.

```bash
./scripts/build-all.sh
```

Default build order follows the sequence in `repos.yaml`.

## Common commands

Build one repo:

```bash
./scripts/build.sh gr4-incubator
```

Profile compile/link memory for a build:

```bash
GR4_BUILD_MEM_PROFILE=1 ./scripts/build-all.sh
GR4_BUILD_MEM_PROFILE=1 ./scripts/build.sh gnuradio4-core
```

This writes a tab-separated log under `var/logs/build-memory/` and prints the
highest max-RSS compile/link commands at the end. Profiling disables ccache for
CMake repos and uses `build/<repo>-mem-profile/` so the measured command is the
compiler or linker work without changing the normal build tree.

Clean one repo build tree:

```bash
./scripts/clean.sh gr4-incubator
```

Clean all build trees:

```bash
./scripts/clean-all.sh
```

Wipe installed artifacts from `install/`:

```bash
./scripts/wipe.sh
# non-interactive
./scripts/wipe.sh --yes
```

## Scaffold New Projects

Create a new local out-of-tree project under `src/`:

```bash
./scripts/scaffold.sh my-new-project
```

By default, that creates a first module with the same normalized name as the
project. If you want a different initial module name, pass it as a second
argument:

```bash
./scripts/scaffold.sh my-new-project filters
```

Add another module to that project:

```bash
./scripts/add-module.sh my-new-project filters
```

Add a block to that module:

```bash
./scripts/add-block.sh my-new-project filters Gain
```

The scaffold is Bash-only and keeps the layout intentionally small:

- `src/gr4-<project>/CMakeLists.txt`
- `src/gr4-<project>/blocks/<module>/CMakeLists.txt`
- `src/gr4-<project>/blocks/<module>/include/gnuradio-4.0/<module>/`
- `src/gr4-<project>/blocks/<module>/test/`

Naming rules:

- project and module names may use lowercase letters, digits, hyphens, and underscores
- block names may use uppercase letters and are typically PascalCase, like `Copy`
- generated filesystem names use hyphens
- generated C++ identifiers use underscores

Hierarchy:

- project: repo under `src/gr4-<project>/`
- module: package under `blocks/<module>/`
- block: header/test pair under a module

## Bootstrap and refs (`repos.yaml`)

`repos.yaml` is the source of truth for:

- `name`
- `url`
- `dest`
- `ref` (branch, tag, or commit)

`./bootstrap.sh` is rerunnable and will:

- clone missing repos
- fetch updates for existing repos
- resolve refs with remote-first preference for branch names (for example `origin/main`)
- check out the resolved target in detached HEAD

If you want to develop on a local branch in a repo, create or switch branches
inside that repo after bootstrap.

## Environment details

`source scripts/dev-env.sh` exports consistent workspace defaults, including:

- `CC`, `CXX` when `GR4_CC` / `GR4_CXX` are set
- `PKGCONF`, `PKG_CONFIG`
- `GR4_PREFIX` and `GR4_PREFIX_PATH`
- `PATH`, `CMAKE_PREFIX_PATH`, `PKG_CONFIG_PATH`
- `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`, `PYTHONPATH`
- `GNURADIO4_PLUGIN_DIRECTORIES`

## Docker Images

`images/` owns the Docker build flow:

- `images/<distro>/base/` for distro-wide prerequisites
- `images/<distro>/profiles/<profile>/` for toolchain-specific layers
- `images/Makefile` for local and multi-arch pushed builder images only
- `images/Dockerfile` for GNU Radio 4, control-plane, runtime, and Studio product images
- `images/build-images.sh` for product image builds and pushes
- `compose.yml` for running the production control-plane plus Studio instance

See [images/README.md](images/README.md) for the full local, GHCR, and
multi-arch image workflow.

Local image build:

```bash
make -C images build-ubuntu-24.04-gcc-14
images/build-images.sh --profile ubuntu-24.04-gcc-14
```

After product images are built or available from GHCR, run the production stack:

```bash
docker compose up
```

By default this uses local `gr4-dev/...` product images. To run hosted images,
set `IMAGE_NAMESPACE`, for example:

```bash
IMAGE_NAMESPACE=ghcr.io/$USER/gr4-dev docker compose up
```

The Compose runtime sets `GNURADIO4_PLUGIN_DIRECTORIES` inside the
control-plane container to include `/usr/local/lib/gnuradio-4/plugins`,
`/usr/local/lib`, and `/opt/gr4-control-plane/lib`. Use
`GR4_DOCKER_PLUGIN_DIRECTORIES` to override that container-local path.

Compose also mounts the repo-local, gitignored `data/` directory into the
control-plane container at `/opt/gr4-control-plane/data`. Since the control
plane runs from `/opt/gr4-control-plane`, graphs can use relative paths under
`data/`. Use `GR4_DOCKER_HOST_DATA_DIR` and `GR4_DOCKER_CONTAINER_DATA_DIR` to
override that mount.

Local product image builds use the workspace repos under `src/`. Push builds
use the `url` and `ref` entries from `repos.yaml`.

## CMake args (shared and local)

For CMake repos, configure args are layered in this order:

1. `config/all.cmake.args` (committed shared defaults)
2. `config/<repo>.cmake.args` (committed per-repo defaults)
3. `build/<repo>/cmake.args` (local overrides, not committed)

`build-all.sh` always applies:

- `-DCMAKE_INSTALL_PREFIX=${GR4_PREFIX_PATH}`

Optional per-repo CMake source override:

- `config/<repo>.cmake.source`

Example: `config/gr4-studio.cmake.source` contains `blocks`, so Studio
configures from `src/gr4-studio/blocks`.

When `build-all.sh` is called without args, it builds repos in `repos.yaml`
order.

## Notes

- No git submodules in this workspace (by design).
- Keep scripts simple and inspectable.
- Preserve repo boundaries; this is a workspace repo, not a monorepo.

## License

This project is licensed under the MIT License.

Copyright (c) 2026 Josh Morman, Altio Labs, LLC

See the LICENSE file for details.
