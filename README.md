# mm-ops-public

Public distribution point for the MediaEmeet server bootstrap. It holds only:

- `bootstrap.sh` (small script, read it before running it)
- the admin package tarball (deployment scripts and PUBLIC keys only)
- their SHA-256 values, which are also recorded in the private project's release record

Never stored here: passwords, private keys, tokens, `.env` files, databases or customer data.

Integrity does not depend on this repository: the operator types the expected SHA-256 and the
bootstrap refuses any file that does not match. Nothing is published here until the independent
review of the exact package is complete.

Status: no package published yet.

## v1/host-readonly-report.sh
Read-only host assessment (changes nothing, no network, prints no secret values).
Pinned SHA-256: `18845b4538425ec774ac505cc3ac2a2162df97baf8973c54891e465ceaf8108f` (see `v1/SHA256SUMS`).
Source: royasazan/Media-Network, branch ops/runner-readiness (0c6ee4c), scripts/ops/host-readonly-report.sh.
Verify before running: `sha256sum -c SHA256SUMS`.
