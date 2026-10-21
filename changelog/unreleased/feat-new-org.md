### Added
- `scripts/export-org.py`: a read-only export of how an org runs the demo (apps, gateway, API Manager instances and policies, Exchange assets, the System API's data), secrets redacted, to keep before a trial org expires (#5)
- README: how to move the demo to a new organization (#5)

### Changed
- With `TRIAL=1`, `deploy-network.sh` waits for the new Omni Gateway to be up before it deploys the broker, so a new org deploys in one run (#5)
