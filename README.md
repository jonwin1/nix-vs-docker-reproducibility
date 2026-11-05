# SC Experiment Setup

```sh
sudo virsh start sc-experiment
sudo virsh domifaddr sc-experiment
ssh sc@<ipaddr>
cd experiment
nix develop nxc/
./scripts/run.sh
./scripts/clean.sh
sudo shutdown
```
