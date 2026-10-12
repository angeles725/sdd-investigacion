#!/bin/sh
# Test shim installed as `node`: passes the capability probe through to the real node, but as the "helper" it emits a record that
# carries the CORRECT nonce (read from stdin) and a non-numeric chars field holding an arithmetic command-substitution payload.
if [ "$1" = "-p" ]; then exec "$RSDD_TEST_REALNODE" "$@"; fi
IFS= read -r n
printf '%s\tS\text.ts\tk\ta[$(touch %s)]\tok\n' "$n" "$RSDD_TEST_CANARY"
printf '%s\tT\text.ts\t1\n%s\tZ\t1\n' "$n" "$n"
