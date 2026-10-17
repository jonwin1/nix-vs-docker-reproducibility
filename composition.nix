{
  roles = {
    foo =
      { pkgs, ... }:
      {
        environment.systemPackages = with pkgs; [
          raftly
        ];
      };
  };
  testScript = ''
    foo.succeed("server -h")
    foo.fail("false")
  '';
}
