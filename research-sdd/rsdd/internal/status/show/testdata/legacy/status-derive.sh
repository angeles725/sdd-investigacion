# disk-DERIVED blocked_open — delegated to lib/blocked-rows.sh blocked_open_count (kit #923), the same function
# verify-state.sh calls: needs:-carrying entries under the standard blocked sections PLUS open entries in
# ## Child gaps surfaced at close (a CLOSED child gap that keeps `needs:` is not counted, #913).
derive_blocked_open() { blocked_open_count "$state"; }
