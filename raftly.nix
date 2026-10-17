{
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule {
  name = "raftly";

  src = fetchFromGitHub {
    owner = "ani03sha";
    repo = "raftly";
    rev = "235a033c44c88a3de0ddd290ab0c522b9770ed41";
    sha256 = "ydyHd7RsE5K1qtPY958KdRDbo4q8EIWunYwLuknpHTQ=";
  };

  vendorHash = "sha256-9xWI1wtlm2H/pQIbFeJ0dtqhqJXL4f3OSgi70dXrNys=";
}
