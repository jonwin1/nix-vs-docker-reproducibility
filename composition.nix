{ pkgs, ... }:
let
  raftly = pkgs.callPackage ./raftly.nix { };

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
  };

  testScript = ''
    node1.wait_until_succeeds("systemctl show-environment >/dev/null")
    node2.wait_until_succeeds("systemctl show-environment >/dev/null")
    node3.wait_until_succeeds("systemctl show-environment >/dev/null")

    node1.wait_for_unit("raftly.service")
    node2.wait_for_unit("raftly.service")
    node3.wait_for_unit("raftly.service")

    node1.wait_for_open_port(8001)
    node2.wait_for_open_port(8002)
    node3.wait_for_open_port(8003)

    node1.succeed("curl -fsS http://127.0.0.1:8001/status")
    node2.succeed("curl -fsS http://127.0.0.1:8002/status")
    node3.succeed("curl -fsS http://127.0.0.1:8003/status")
  '';
}
