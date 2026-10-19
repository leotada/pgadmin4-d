#!/usr/bin/env bash
set -euo pipefail

# Determine script root directory
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_D_DIR="${ROOT_DIR}/server-d"

BUILD_MODE="debug"
BUILD_JINJA=false
RUN_TESTS=false
FORCE_REBUILD=false

print_help() {
    cat <<EOF
Usage: ./build.sh [OPTIONS]

Compiles the D backend for pgAdmin 4 located in server-d/.

Options:
  -r, --release      Build with release optimizations (--build=release)
  -f, --force        Force a full rebuild from scratch (--force)
  -a, --all          Build both pgadmin4-d and jinja-cli
  -t, --test         Run the test suite (dub test)
  -c, --clean        Clean build artifacts in server-d/
  -h, --help         Show this help message

Outputs:
  server-d/bin/pgadmin4-d   Main backend server binary
  server-d/bin/jinja-cli    Jinja template CLI renderer (when using -a)

Examples:
  ./build.sh                 # Fast debug build
  ./build.sh --release       # Optimized release build
  ./build.sh --test          # Run unittests
  ./build.sh -a --release    # Release build of both server and jinja-cli
EOF
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--release)
            BUILD_MODE="release"
            shift
            ;;
        -f|--force)
            FORCE_REBUILD=true
            shift
            ;;
        -a|--all)
            BUILD_JINJA=true
            shift
            ;;
        -t|--test)
            RUN_TESTS=true
            shift
            ;;
        -c|--clean)
            echo "==> Cleaning server-d build artifacts..."
            rm -rf "${SERVER_D_DIR}/bin" "${SERVER_D_DIR}/.dub"
            echo "==> Done."
            exit 0
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use ./build.sh --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ ! -d "${SERVER_D_DIR}" ]]; then
    echo "Error: Directory ${SERVER_D_DIR} not found!" >&2
    exit 1
fi

cd "${SERVER_D_DIR}"

DUB_ARGS=()
if [[ "${BUILD_MODE}" == "release" ]]; then
    DUB_ARGS+=("--build=release")
fi
if [[ "${FORCE_REBUILD}" == true ]]; then
    DUB_ARGS+=("--force")
fi

if [[ "${RUN_TESTS}" == true ]]; then
    echo "==> Running tests in server-d (dub test)..."
    dub test "${DUB_ARGS[@]}"
    echo "==> All tests passed!"
    exit 0
fi

echo "==> Building pgAdmin 4 backend (mode: ${BUILD_MODE})..."
dub build "${DUB_ARGS[@]}"
echo "==> Server built successfully: server-d/bin/pgadmin4-d"

if [[ "${BUILD_JINJA}" == true ]]; then
    echo "==> Building jinja-cli..."
    dub build -c jinja-cli "${DUB_ARGS[@]}"
    echo "==> Jinja CLI built successfully: server-d/bin/jinja-cli"
fi

echo ""
echo "To run pgAdmin 4 backend:"
echo "  cd server-d && ./bin/pgadmin4-d --web-dir ../web --port 5050"
