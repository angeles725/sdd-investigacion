#!/usr/bin/env bash
cat >/dev/null; head -c 10500 /dev/zero | tr "\0" b
