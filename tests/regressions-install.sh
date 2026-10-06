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
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --connect-timeout|--max-time|--max-filesize|--speed-limit|--speed-time) shift 2 ;;
    -o) output=$2; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in *'//releases/'*) exit 1 ;; esac
case "$url" in
  */latest)
    [ "${INSTALL_TEST_FAIL:-}" != latest ] || exit 1
    printf '%s\n' "${INSTALL_TEST_VERSION:-1.2.3}" ;;
  */checksums.txt)
    [ "${INSTALL_TEST_FAIL:-}" != checksums ] || exit 1
    case "${INSTALL_TEST_CHECKSUM_MODE:-normal}" in
      corrupt) printf '%064d  %s\n' 0 "$INSTALL_TEST_ASSET" >"$output" ;;
      binary) printf '%s *%s\n' "$INSTALL_TEST_DIGEST" "$INSTALL_TEST_ASSET" >"$output" ;;
      uppercase)
        digest=$(printf '%s' "$INSTALL_TEST_DIGEST" | tr 'a-f' 'A-F')
        printf '%s  %s\n' "$digest" "$INSTALL_TEST_ASSET" >"$output" ;;
      crlf) printf '%s  %s\r\n' "$INSTALL_TEST_DIGEST" "$INSTALL_TEST_ASSET" >"$output" ;;
      malformed)
        printf '%s  %s\nmalformed\n' "$INSTALL_TEST_DIGEST" "$INSTALL_TEST_ASSET" >"$output" ;;
      duplicate)
        printf '%s  %s\n%s  %s\n' "$INSTALL_TEST_DIGEST" "$INSTALL_TEST_ASSET" "$INSTALL_TEST_DIGEST" "$INSTALL_TEST_ASSET" >"$output" ;;
      *) printf '%s  %s\n' "$INSTALL_TEST_DIGEST" "$INSTALL_TEST_ASSET" >"$output" ;;
    esac
    ;;
  *)
    [ "${INSTALL_TEST_FAIL:-}" != asset ] || exit 1
    case "$output" in
      "$INSTALL_TEST_ROOT/install/".tx9-install.*/*) ;;
      *) printf 'download not staged beside destination\n' >&2; exit 1 ;;
    esac
    cp "$INSTALL_TEST_ROOT/payload" "$output"
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

for mode in binary uppercase crlf; do
  if ! INSTALL_TEST_CHECKSUM_MODE="$mode" sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"; then
    cat "$tmp/install.log" >&2
    echo "installer rejected valid $mode checksums" >&2
    exit 1
  fi
done

TX9_ORIGIN="${TX9_ORIGIN}///" sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"

printf 'old binary\n' >"$TX9_INSTALL_DIR/tx9"
for mode in corrupt malformed duplicate; do
  if INSTALL_TEST_CHECKSUM_MODE="$mode" sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"; then
    echo "installer accepted $mode checksums" >&2
    exit 1
  fi
  [[ "$(cat "$TX9_INSTALL_DIR/tx9")" == 'old binary' ]]
  [[ "$(find "$TX9_INSTALL_DIR" -name '.tx9-install.*' -print)" == '' ]]
done

for resource in latest checksums asset; do
  if INSTALL_TEST_FAIL="$resource" sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"; then
    echo "installer accepted a failed $resource download" >&2
    exit 1
  fi
  [[ "$(cat "$TX9_INSTALL_DIR/tx9")" == 'old binary' ]]
  [[ "$(find "$TX9_INSTALL_DIR" -name '.tx9-install.*' -print)" == '' ]]
done

for version in '../1.2.3' '1.2.3/extra' '1.2' '1..3'; do
  if INSTALL_TEST_VERSION="$version" sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"; then
    echo "installer accepted an invalid version: $version" >&2
    exit 1
  fi
  [[ "$(cat "$TX9_INSTALL_DIR/tx9")" == 'old binary' ]]
  [[ "$(find "$TX9_INSTALL_DIR" -name '.tx9-install.*' -print)" == '' ]]
done

rm "$TX9_INSTALL_DIR/tx9"
mkdir "$TX9_INSTALL_DIR/tx9"
if sh "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>"$tmp/install.log"; then
  echo 'installer accepted a directory as its destination' >&2
  exit 1
fi
[[ ! -e "$TX9_INSTALL_DIR/tx9/$INSTALL_TEST_ASSET" ]]
echo 'installer regression checks passed'
