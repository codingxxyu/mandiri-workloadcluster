# Optional data-disk notes

Deployment no longer requires Storage v2 or `storagectl` before creating the control-plane Pool.

R&D guidance for this site:

- During install, only pin the OS disk with `/dev/elemental-install-target`.
- Extra disks are not declared in `MachineInventory.spec.storage`.
- After the workload cluster is Ready, log into the node and mount extra disks as needed.
- Later OS or cluster upgrades do not depend on that extra-disk layout.

`storage.template.yaml` is kept only as an optional reference. Do not treat it as a required deployment gate.
