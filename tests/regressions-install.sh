#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

mkdir -p "$tmp/bin" "$tmp/install"
export INSTALL_TEST_ROOT="$tmp"
cat >"$tmp/payload" <<'EOF'
#!/bin/sh
printf '1.2.3\n'
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
set -eu
url=$2
case "$url" in
  */latest) printf '1.2.3\n' ;;
  */checksums.txt)
    if [ "${INSTALL_TEST_CORRUPT:-0}" = 1 ]; then
      printf '%064d  %s\n' 0 "$INSTALL_TEST_ASSET" >"$4"
    else
      printf '%s  %s\n' "$INSTALL_TEST_DIGEST" "$INSTALL_TEST_ASSET" >"$4"
    fi
    ;;
  *)
    case "$4" in
      "$INSTALL_TEST_ROOT/install/".tx9-install.*/*) ;;
      *) printf 'download not staged beside destination\n' >&2; exit 1 ;;
    esac
    cp "$INSTALL_TEST_ROOT/payload" "$4"
    ;;
esac
EOF
chmod 0700 "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
export TX9_INSTALL_DIR="$tmp/install"
export TX9_ORIGIN=https://releases.invalid
case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
export INSTALL_TEST_ASSET="tx9_${os}_${arch}"
export INSTALL_TEST_DIGEST
INSTALL_TEST_DIGEST="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/payload")"

sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"
cmp "$tmp/payload" "$TX9_INSTALL_DIR/tx9"
[[ -x "$TX9_INSTALL_DIR/tx9" ]]
[[ "$(find "$TX9_INSTALL_DIR" -name '.tx9-install.*' -print)" == '' ]]

printf 'old binary\n' >"$TX9_INSTALL_DIR/tx9"
if INSTALL_TEST_CORRUPT=1 sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"; then
  echo 'installer accepted a checksum mismatch' >&2
  exit 1
fi
[[ "$(cat "$TX9_INSTALL_DIR/tx9")" == 'old binary' ]]
[[ "$(find "$TX9_INSTALL_DIR" -name '.tx9-install.*' -print)" == '' ]]

rm "$TX9_INSTALL_DIR/tx9"
mkdir "$TX9_INSTALL_DIR/tx9"
if sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"; then
  echo 'installer accepted a directory as its destination' >&2
  exit 1
fi
[[ ! -e "$TX9_INSTALL_DIR/tx9/$INSTALL_TEST_ASSET" ]]
echo 'installer regression checks passed'
