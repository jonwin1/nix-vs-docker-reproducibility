# SC Experiment Setup

The following experiment should be runnable on any Linux PC with virtualisation
support and Nix installed ([Download Nix](https://nixos.org/download/#download-nix)).

1. Build the experiment VM.

    ```sh
    nix build --impure --out-link /tmp/sc-experiment-vm .#nixosConfigurations.vm.config.system.build.vm
    ```

    > `--impure` is required to share the project directory with the VM.
    > `--out-link` sets the build output location (so that it is not in the
    > shared directory).

2. Start the VM and wait for it to open in a new window.

    ```sh
    /tmp/sc-experiment-vm/bin/run-nixos-vm
    ```

3. Inside the VM.

    1. Log in with the username and password *user*.

    2. Enter the experiment environment.

        ```sh
        cd experiment
        nix develop nxc/
        ```

    3. Run the experiment scripts.

        ```sh
        ./scripts/run.sh
        ```

    4. Stop the VM.

        ```sh
        sudo poweroff
        ```

4. The results can be found in a directory called results followed by the date
   and time of the run.

The VM has no persistent storage, which means that the next time it is started
there is no cache or old builds remaining that could affect future results.

## AI Disclaimer

Some of the scripts in this project were created with AI assisted development.
