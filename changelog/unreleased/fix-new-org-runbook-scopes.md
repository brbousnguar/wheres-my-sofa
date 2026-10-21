### Fixed
- README: the connected app also needs Read Runtime Fabrics and CloudHub Network Viewer on the business group, or `deploy-apps.sh` fails at the target lookup with a 403 (#7)
- With `TRIAL=1`, `deploy-network.sh` reuses a gateway that already has the name, so a run that stopped after the gateway step can be repeated (#7)
