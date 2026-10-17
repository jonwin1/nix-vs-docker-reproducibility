{ pkgs, ... }: {
  roles = {
    foo =
      { pkgs, ... }:
      {
        environment.systemPackages = with pkgs; [ socat ];
      };
  };
  testScript = ''
    foo.succeed("true")
    foo.fail("false")
  '';
}
