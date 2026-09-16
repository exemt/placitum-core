#!/bin/sh
# Archive buckets with lifecycle rules filtered by the waf-retain-ttl tag.
# Idempotent: import replaces the whole bucket configuration.

set -e

for bucket in waf-headers waf-args waf-bodies; do
    mc mb --ignore-existing "waf/$bucket"
    mc ilm import "waf/$bucket" < /etc/waf/lifecycle.json
done

mc ilm rule ls waf/waf-bodies
