{ pkgs, ... }:
let
  raftlySrc = ../raftly;
  raftlyVendorHash = "sha256-9xWI1wtlm2H/pQIbFeJ0dtqhqJXL4f3OSgi70dXrNys=";

  raftly = pkgs.callPackage ./raftly.nix {
    src = raftlySrc;
    vendorHash = raftlyVendorHash;
  };

  raftlyScenarioSource = pkgs.buildGoModule {
    pname = "raftly-scenario-source";
    version = "0.1.0";

    src = raftlySrc;
    vendorHash = raftlyVendorHash;

    doCheck = false;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a ./. "$out/"
      runHook postInstall
    '';
  };

  scenarioRunner = pkgs.writeShellApplication {
    name = "raftly-scenarios";

    runtimeInputs = with pkgs; [
      bash
      coreutils
      go
    ];

    text = ''
      export RAFTLY_DIR="${raftlyScenarioSource}"
      export GOFLAGS="-mod=vendor"
      export GOTOOLCHAIN=local

      export RESULTS_DIR="''${RESULTS_DIR:-/var/tmp/raftly-results/scenarios}"

      cd "${raftlyScenarioSource}"

      exec bash "${../scripts/scenarios.sh}"
    '';
  };

  clusterTestRunner = pkgs.writeShellApplication {
    name = "raftly-cluster-tests";

    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
      jq
    ];

    text = ''
      export RESULTS_DIR="''${RESULTS_DIR:-/var/tmp/raftly-results/cluster}"

      exec bash "${../scripts/cluster-tests.sh}" "$@"
    '';
  };

  mkNode =
    {
      id,
      grpcPort,
      httpPort,
      peers,
      httpPeers,
    }:
    {
      networking.firewall.allowedTCPPorts = [
        grpcPort
        httpPort
      ];

      systemd.services.raftly = {
        description = "Raftly node ${id}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          Type = "simple";
          DynamicUser = true;
          StateDirectory = "raftly-${id}";
          Restart = "on-failure";
          RestartSec = 2;

          ExecStart = ''
            ${raftly}/bin/raftly-server \
              -id=${id} \
              -grpc-addr=:${toString grpcPort} \
              -http-addr=:${toString httpPort} \
              -data-dir=/var/lib/raftly-${id} \
              -peers=${peers} \
              -http-peers=${httpPeers}
          '';
        };
      };
    };
in
{
  nodes = {
    node1 = mkNode {
      id = "node1";
      grpcPort = 7001;
      httpPort = 8001;
      peers = "node2=node2:7002,node3=node3:7003";
      httpPeers = "node1=node1:8001,node2=node2:8002,node3=node3:8003";
    };

    node2 = mkNode {
      id = "node2";
      grpcPort = 7002;
      httpPort = 8002;
      peers = "node1=node1:7001,node3=node3:7003";
      httpPeers = "node1=node1:8001,node2=node2:8002,node3=node3:8003";
    };

    node3 = mkNode {
      id = "node3";
      grpcPort = 7003;
      httpPort = 8003;
      peers = "node1=node1:7001,node2=node2:7002";
      httpPeers = "node1=node1:8001,node2=node2:8002,node3=node3:8003";
    };

    runner = {
      environment.systemPackages = [
        scenarioRunner
        clusterTestRunner

        pkgs.gcc
      ];
    };
  };

  testScript = ''
    # Wait for cluster startup
    node1.wait_until_succeeds("systemctl show-environment >/dev/null")
    node2.wait_until_succeeds("systemctl show-environment >/dev/null")
    node3.wait_until_succeeds("systemctl show-environment >/dev/null")
    runner.wait_until_succeeds("systemctl show-environment >/dev/null")

    node1.wait_for_unit("raftly.service")
    node2.wait_for_unit("raftly.service")
    node3.wait_for_unit("raftly.service")
    runner.wait_for_unit("multi-user.target")

    node1.wait_for_open_port(8001)
    node2.wait_for_open_port(8002)
    node3.wait_for_open_port(8003)

    failures = []

    def run_test(name, command, timeout):
        print(f"\nRunning: {name}")

        try:
            output = runner.succeed(command, timeout=timeout)
            print(output)
        except Exception as e:
            print(f"FAILED: {name}: {e}")
            failures.append(name)


    try:
        # Four Go-based failure scenarios
        run_test("scenario runner", "raftly-scenarios", 300)

        # Six cluster tests
        scenarios = [
            "baseline",
            "burst",
            "delay",
            "packet-loss",
            "follower-isolation",
            "leader-isolation",
        ]

        for scenario in scenarios:
            run_test(
                f"cluster test: {scenario}",
                f"raftly-cluster-tests {scenario}",
                120,
            )

    finally:
        print("Collecting test results...")
        runner.succeed("mkdir -p /var/nxc/shared/raftly-results")
        runner.succeed("cp -a /var/tmp/raftly-results/. /var/nxc/shared/raftly-results/")

    if failures:
        raise Exception("Failed test suites: " + ", ".join(failures))

    print("\nAll test suites passed.")
  '';
}
