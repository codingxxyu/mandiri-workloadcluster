# 100G `/var/cpaas` Data Disk

The three registered masters each have a 300G system disk and a 100G data disk.

- 300G: Alauda OS installation disk selected by `MachineRegistration.spec.config.elemental.install.device`.
- 100G: managed data disk mounted at `/var/cpaas` through `MachineInventory.spec.storage`.

Do not guess the 100G disk ID and do not use `/dev/sdb`. For each inventory, read `status.observedStorage.devices[]` and select the actual stable ID whose `systemRole` is `Data` and size is approximately 100G.

Copy `storage.template.yaml` once per master, replace the stable `deviceID`, and use the matching ACP 4.3.2 `storagectl` to render an atomic patch. `InitializeIfBlank` may format the selected disk and therefore requires explicit approval. Full commands are in the root README.
