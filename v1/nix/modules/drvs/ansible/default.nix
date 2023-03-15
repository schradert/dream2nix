{
  config,
  lib,
  ...
}: let
  l = lib // builtins;
  python = config.deps.python;
in {
  imports = [
    ../../drv-parts/mach-nix-xs
    ../../drv-parts/lock
  ];

  lock.fields.mach-nix.pythonSources = let
    safeFOD = config.mach-nix.pythonSources.overrideAttrs (old: {
      outputHash = l.fakeSha256;
    });

    deps = safeFOD.overrideAttrs (old: {
      outputHash = null;
      phases = ["foo"];
      foo = "touch $out";
    });
  in
    config.deps.writePython3 "update-FOD-hash-${config.public.name}" {} ''
      import os
      import json
      import subprocess

      out_path = os.getenv("out")
      drv_path = "${l.unsafeDiscardStringContext safeFOD.drvPath}"  # noqa: E501
      nix_build = ["${config.deps.nix}/bin/nix", "build", "-L"]  # noqa: E501
      nix_build_deps = nix_build + ["${l.unsafeDiscardStringContext deps.drvPath}"]  # noqa: E501
      nix_build_failing = nix_build + [drv_path]  # noqa: E501

      subprocess.run(nix_build_deps, check=True)
      with subprocess.Popen(nix_build_failing, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:  # noqa: E501
          for line in process.stdout:
              line = line.strip()
              if line == f"error: hash mismatch in fixed-output derivation '{drv_path}':":  # noqa: E501
                  specified = next(process.stdout).strip().split(" ", 1)
                  got = next(process.stdout).strip().split(" ", 1)
                  assert specified[0].strip() == "specified:"
                  assert got[0].strip() == "got:"
                  hash = got[1].strip()
                  print(f"Found new hash: {hash}")
                  break
              print(line)
      with open(out_path, 'w') as f:
          json.dump(hash, f, indent=2)
    '';

  deps = {nixpkgs, ...}: {
    python = nixpkgs.python39;
    inherit (nixpkgs.writers) writePython3;
  };

  name = "ansible";
  version = "2.7.1";

  mkDerivation = {
    preUnpack = ''
      export src=$(ls ${config.mach-nix.pythonSources}/names/${config.name}/*);
    '';
  };

  buildPythonPackage = {
    format = "setuptools";

    pythonImportsCheck = [
      config.name
    ];
  };

  mach-nix.pythonSources = config.deps.fetchPip {
    inherit python;
    name = config.public.name;
    requirementsList = ["${config.public.name}==${config.public.version}"];
    hash = config.lock.content.mach-nix.pythonSources;
    maxDate = "2023-01-01";
  };
}
