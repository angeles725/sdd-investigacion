# Cloudflare Tunnel — new client from zero

How to stand up a Cloudflare Tunnel for a brand-new client with no existing toolchain: the
ordered API sequence, the packaging/hardening checklist shape, and where this fits against the
other Cloudflare and Windows-SSH docs in this toolbelt.

**Scope.** This file covers the **new-client bring-up sequence** — the steps a brand-new
Cloudflare account/zone needs before a tunnel can carry traffic. It complements, and does not
replace:
- [`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md) — provisioning `sshd` + `cloudflared` on the
  Windows host once a tunnel/connector token already exists.
- [`DEPLOY-CLOUDFLARE-WORKERS.md`](DEPLOY-CLOUDFLARE-WORKERS.md) — deploying Worker scripts via
  the REST API (a different Cloudflare product surface).

_Source: kit issue #1896; evidence B24 §24.3-24.9, B25 §25.6-25.11,
`HOWTO-CREAR-TUNEL-CLOUDFLARE.md` Parte A._

## 1. Ordered API sequence

Standing up a tunnel for a client with zero existing Cloudflare toolchain follows this order —
each step depends on an identifier or token returned by the previous one:

1. **Verify the API token.** Confirm the token being used has the scopes the remaining steps need
   before attempting anything else; a scope gap surfaces later as an opaque 403 on whichever step
   needs the missing permission.
2. **List existing tunnels** for the account/zone, to avoid creating a duplicate and to confirm the
   token can actually read tunnel state.
3. **Create the tunnel** with `config_src: cloudflare` (dashboard-managed configuration, as
   opposed to a locally-managed `config.yml`).
4. **Configure ingress** rules for the new tunnel (hostname → local service mapping).
5. **Create the CNAME** DNS record pointing the public hostname at the tunnel.
6. **Obtain the connector token** for the tunnel (the `cloudflared` service install consumes this
   token — see [`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md) §3 for the service-install step
   itself, and the tool-registry's "Cloudflare Tunnel — operational scars" entry for the
   `eyJ`-prefixed connector token vs `cfut_`-prefixed API token distinction).
7. **Create the Access application** protecting the hostname.
8. **Configure the CA** (certificate authority) for the Access application, when short-lived
   certificate auth is in scope.
9. **Configure the Access policy** (who/what is allowed through).
10. **Configure an alert** for the tunnel/Access application, so a connectivity or policy failure
    is observable rather than silent.

Each step's output (tunnel ID, connector token, Access app ID) is an input to a later step; doing
them out of order means re-fetching an identifier a later step assumed was already in hand.

## 2. Dashboard menu paths

The source retro records the **current** dashboard click-paths used to reach each of the steps
above at the time of capture (B24 §24.3-24.9, B25 §25.6-25.11). Cloudflare's dashboard navigation
changes between releases faster than this doc is reviewed — record the exact click-path only from
a verified-current dashboard session, not from memory of a past one, when absorbing this section
further.

## 3. Bundle / packaging rules

The client-side bundle (`tunnel/Cliente/NavePanccadia/` — see
[`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md) header) packages the connector token and
service-install script together. Keep the packaging rule from the source retro in mind when
assembling a new client's bundle: the connector token is client-specific and must not be reused
across clients, and the bundle should fail loudly (not silently install with a stale/placeholder
token) if the token slot is empty — the same token-pitfall class already documented in the
tool-registry's "Cloudflare Tunnel — operational scars" entry (`config.example.ps1` →
`config.ps1` overwrite trap).

## 4. Post-install hardening checklist

After the tunnel and Access application are live, the post-install checklist (B24 §24.3-24.9,
B25 §25.6-25.11) covers at minimum:
- Confirming the Access policy actually restricts access to the intended identities (not left at
  a permissive default from creation).
- Confirming the alert configured in step 10 above actually fires on a deliberate failure (do not
  trust an alert that has never been exercised).
- Confirming the CA/certificate configuration (step 8) matches the authentication mode the client
  actually needs (short-lived cert vs. standard Access login).

## Cross-reference (deferred)

- `tool-registry.md` should gain a row for this new-client bring-up sequence, pointing at this
  file — `tool-registry.md` is owned by another writer in this chain; add the row when that file
  is next touched.
- [`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md)'s header already references the
  `tunnel/Cliente/NavePanccadia/` bundle this file's §3 discusses; a forward cross-link from there
  to this file can be added in the same pass as the registry row above.
