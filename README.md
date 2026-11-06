# SC Experiment Setup

The following experiment should be runnable on any Linux PC with virtualisation
support and Nix installed ([Download Nix](https://nixos.org/download/#download-nix)).

1. Build the experiment VM.

    ```sh
    nix build --impure .#nixosConfigurations.vm.config.system.build.vm
    ```

    > `--impure` is required to share the current directory with the VM.

2. Start the VM and wait for it to open in a new window.

    ```sh
    ./result/bin/run-nixos-vm
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

## TODO

- Licence
- Make public
- Try different versions
- 5 runs per week

## AI Disclaimer

Some of the scripts in this project were created with AI assisted development.
