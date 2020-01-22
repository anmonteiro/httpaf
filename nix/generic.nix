{ lib, stdenv, ocamlPackages, gitignoreSource, doCheck }:

with ocamlPackages;

let
  buildHttpaf = args: buildDunePackage ({
    version = "0.6.5-dev";
    doCheck = doCheck;
    src = gitignoreSource ./..;
  } // args);

# TODO: httpaf-async, httpaf-mirage
in rec {
  httpaf = buildHttpaf {
    pname = "httpaf";
    buildInputs = [ alcotest hex yojson ];
    propagatedBuildInputs = [
      angstrom
      faraday
    ];
  };

  # These two don't have tests
  httpaf-lwt = buildHttpaf {
    pname = "httpaf-lwt";
    doCheck = false;
    propagatedBuildInputs = [ httpaf lwt4 ];
  };

  httpaf-lwt-unix = buildHttpaf {
    pname = "httpaf-lwt-unix";
    doCheck = false;
    propagatedBuildInputs = [
      httpaf-lwt
      faraday-lwt-unix
      lwt_ssl
    ];
  };
}