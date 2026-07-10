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

Targets **Ubuntu 24.04** with **Clang 20 + libc++** and **C++23**.

1. Install system libraries, the Clang 20 toolchain, and Node.js 20 (for Studio).
   All require sudo:

```bash
# system libraries
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake ninja-build pkg-config git ccache wget \
  cppzmq-dev libboost-system-dev libbrotli-dev libcurl4-openssl-dev \
  libcpp-httplib-dev libfftw3-dev libgtest-dev libssl-dev libtbb-dev \
  nlohmann-json3-dev pybind11-dev libcli11-dev librtaudio-dev \
  libportaudio2 libsoapysdr-dev soapysdr-module-hackrf soapysdr-tools \
  python3 python3-dev python3-numpy

# Clang 20 + libc++ (LLVM apt repo)
sudo install -d -m 0755 /etc/apt/keyrings
wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/llvm.gpg
echo "deb [signed-by=/etc/apt/keyrings/llvm.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble-20 main" | sudo tee /etc/apt/sources.list.d/llvm20.list
sudo apt-get update
sudo apt-get install -y clang-20 libc++-20-dev libc++abi-20-dev libunwind-20-dev

# Node.js 20 (Studio frontend)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

2. Create the local env file and set the compiler to Clang 20:

```bash
cp .env.example .env
# then set in .env:
#   GR4_CC=clang-20
#   GR4_CXX=clang++-20
```

3. Bootstrap repos from `repos.yaml`.

```bash
./bootstrap.sh
```

4. Validate workspace state.

```bash
./scripts/doctor.sh
```

5. Load the environment in your shell. Do this each time a new shell is opened.

```bash
source scripts/dev-env.sh
```

   Steps 6–9 build with **Clang + libc++**, and must run in this **same shell**
   (they share the exported environment). Clang needs libc++ to compile GR4's
   C++23 (`std::ranges::to`); forcing libc++ everywhere keeps the whole stack —
   core, plugins, and control-plane — on one standard library so plugins load at
   runtime.

6. Vendor a header-only `cpp-httplib` into the prefix. Ubuntu's `cpp-httplib` is
   a libstdc++-compiled `.so` that cannot link into libc++ code; the upstream
   single header compiles inline instead. `find_package(httplib)` picks this up:

```bash
mkdir -p install/include install/lib/cmake/httplib
curl -fsSL https://raw.githubusercontent.com/yhirose/cpp-httplib/v0.18.1/httplib.h \
  -o install/include/httplib.h
cat > install/lib/cmake/httplib/httplibConfig.cmake <<'EOF'
get_filename_component(_httplib_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(NOT TARGET httplib::httplib)
  add_library(httplib::httplib INTERFACE IMPORTED)
  set_target_properties(httplib::httplib PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_httplib_prefix}/include")
endif()
set(httplib_FOUND TRUE)
EOF
```

7. Disable tests and examples per repo (local build overrides, created before
   building — system GTest is libstdc++ and won't link under libc++):

```bash
for name in gnuradio4-core gnuradio4-algorithm gnuradio4-blocks \
            gr4-incubator gnuradio4-studio; do
  mkdir -p "build/$name"
  printf -- '-DENABLE_TESTING=OFF\n-DENABLE_EXAMPLES=OFF\n' > "build/$name/cmake.args"
done
```

8. Build and install the library repos, forcing libc++ via `CXXFLAGS`/`LDFLAGS`.
   `GR4_BUILD_JOBS` caps parallelism so the build does not run out of memory —
   each C++23 translation unit can use several GB, and under WSL an uncapped
   build can kill the VM. Building `gnuradio4-studio` also builds its web
   frontend (`npm install && npm run build`) automatically.

```bash
export CXXFLAGS="-stdlib=libc++ -Wno-deprecated-declarations"
export LDFLAGS="-stdlib=libc++"
GR4_BUILD_JOBS=6 ./scripts/build-all.sh \
  gnuradio4-core gnuradio4-algorithm gnuradio4-blocks \
  gr4-incubator gnuradio4-studio
```

9. Build and install the control-plane. It always builds its GTest tests (which
   won't link under libc++), so build only the two real targets, then install
   them (this reuses the `CXXFLAGS`/`LDFLAGS` exported above):

```bash
cmake -S src/gnuradio4-control-plane -B build/gnuradio4-control-plane -GNinja \
  -DCMAKE_INSTALL_PREFIX="$GR4_PREFIX_PATH" -DENABLE_TESTING=OFF
cmake --build build/gnuradio4-control-plane --target gr4cp_server gr4cp_cli_exec -j6
cmake --install build/gnuradio4-control-plane
```

10. Run it. Start the control-plane (it reflects the full block catalog before
    listening, ~15 s), then the Studio dev server:

```bash
./scripts/start-dev.sh                     # control-plane on http://localhost:8080
curl http://localhost:8080/healthz         # -> {"ok":true} once ready
(cd src/gnuradio4-studio && npm run dev)    # Studio UI on http://localhost:5173
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
