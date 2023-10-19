{
  config,
  lib,
  dream2nix,
  specialArgs,
  ...
}: let
  l = lib // builtins;
  cfg = config.WIP-nodejs-builder-v3;

  inherit (config.deps) fetchurl;

  nodejsLockUtils = import ../../../lib/internal/nodejsLockUtils.nix {inherit lib;};
  graphUtils = import ../../../lib/internal/graphUtils.nix {inherit lib;};

  isLink = plent: plent ? link && plent.link;

  parseSource = plent: name:
    if isLink plent
    then
      # entry is local file
      (builtins.dirOf cfg.packageLockFile) + "/${plent.resolved}"
    else
      config.deps.mkDerivation {
        inherit name;
        inherit (plent) version;
        src = fetchurl {
          url = plent.resolved;
          hash = plent.integrity;
        };
        dontBuild = true;
        unpackPhase = ''
          runHook preUnpack
          unpackFallback(){
            local fn="$1"
            tar xf "$fn"
          }
          unpackCmdHooks+=(unpackFallback)
          unpackFile $src
          chmod -R +X .
          runHook postUnpack
        '';
        installPhase = ''
          if [ -f "$src" ]
          then
            # Figure out what directory has been unpacked
            packageDir="$(find . -maxdepth 1 -type d | tail -1)"
            echo "packageDir $packageDir"
            # Restore write permissions
            find "$packageDir" -type d -exec chmod u+x {} \;
            chmod -R u+w -- "$packageDir"
            # Move the extracted tarball into the output folder
            mv -- "$packageDir" $out
          elif [ -d "$src" ]
          then
            strippedName="$(stripHash $src)"
            echo "strippedName $strippedName"
            # Restore write permissions
            chmod -R u+w -- "$strippedName"
            # Move the extracted directory into the output folder
            mv -- "$strippedName" $out
          fi
        '';
      };
  # Lock -> Pdefs
  parse = lock:
    builtins.foldl'
    (acc: entry:
      acc
      // {
        ${entry.name} = acc.${entry.name} or {} // entry.value;
      })
    {}
    # [{name=; value=;} ...]
    (l.mapAttrsToList (parseEntry lock) lock.packages);

  ############################################################
  pdefs = parse cfg.packageLock;
  groups.all.packages = parse cfg.packageLock;

  ############################################################
  # Utility functions #

  # Type: lock.packages -> Info
  getInfo = path: plent: {
    initialPath = path;
    initialState =
      if
        isLink plent
        ||
        /*
        IsRoot
        */
        path == ""
      then "source"
      else "dist";

    pdefs' = graphUtils.sanitizeGraph {
      graph = pdefsToGraph {
        pdefs = groups.all.packages;
        root = {inherit (plent) name version;};
      };
      roots = ["${plent.name}/${plent.version}"];
    };
  };

  # Type: lock.packages -> Bins
  getBins = path: plent:
    if plent ? bin
    then
      if l.isAttrs plent.bin
      then plent.bin
      else if l.isList plent.bin
      then {} l.foldl' (res: bin: res // {${bin} = bin;}) {} plent.bin
      else throw ""
    else {};

  getDependencies = lock: path: plent:
    l.mapAttrs (name: _descriptor: {
      dev = plent.dev or false;
      version = let
        # Need this util as dependencies no explizitly locked version
        # This findEntry is needed to find the exact locked version
        packageIdent = nodejsLockUtils.findEntry lock path name;
      in
        # Read version from package-lock entry for the resolved package
        lock.packages.${packageIdent}.version;
    })
    (plent.dependencies or {} // plent.devDependencies or {} // plent.optionalDependencies or {});

  /*
  pdefs.${name}.${version} :: {
   // [REQUIRED] all dependency entries of that package. (Might be empty)
   // each dependency is guaranteed to have its own entry in 'pdef'
   // A package without dependencies has `dependencies = {}` (So dependencies has a constant type)
   dependencies = {
     ${name} = {
       dev = boolean;
       version :: string;
     }
   }
   ->
   Graph :: { ${id} :: [ String ] }

  */
  pdefsToGraph = {
    pdefs,
    root,
  }:
    l.foldl' (graph: name:
      graph
      // (l.foldl' (g: version: let
          inherit (pdefs.${name}.${version}) dependencies;
        in
          g
          // {
            "${name}/${version}" = l.map (
              n: "${n}/${dependencies.${n}.version}"
              # n: "${n}/${dependencies.${n}.version}"
            ) (l.attrNames dependencies);
          }) {}
        (l.attrNames
          pdefs.${name})))
    {} (l.attrNames pdefs);

  # Takes one entry of "package" from package-lock.json
  parseEntry = lock: path: entry: let
    info = getInfo path entry;
    makeNodeModules = ./build-node-modules.mjs;
    installTrusted = ./install-trusted-modules.mjs;
  in
    if path == ""
    then let
      source = builtins.dirOf cfg.packageLockFile;
      prepared-dev = config.deps.mkDerivation {
        name = entry.name + "-node_modules-dev";
        inherit (entry) version;
        dontUnpack = true;
        env = {
          FILESYSTEM = builtins.toJSON (getFileSystem groups.all.packages);
        };
        buildInputs = with config.deps; [nodejs];
        buildPhase = ''
          node ${makeNodeModules}
        '';
      };
      dist = config.deps.mkDerivation {
        inherit (entry) version;
        name = entry.name + "-dist";
        src = source;
        buildInputs = with config.deps; [nodejs jq];
        env = {
          TRUSTED = builtins.toJSON cfg.trustedDeps;
        };
        configurePhase = ''
          cp -r ${prepared-dev}/node_modules node_modules
          node ${installTrusted}
        '';
        buildPhase = ''
          echo "BUILDING... $name"
          if [ "$(jq '.scripts.build' ./package.json)" != "null" ]; then
            echo "npm run build"
            npm run build
          fi;
        '';
        installPhase = ''
          cp -r . $out
        '';
      };
    in {
      # Root level package
      name = entry.name;
      value = {
        ${entry.version} = {
          dependencies = getDependencies lock path entry;
          inherit info prepared-dev source dist;
          public = {
            out = dist;
            inherit dist;
          };
        };
      };
    }
    else let
      name = l.last (builtins.split "node_modules/" path);
      source = parseSource entry name;
      bins = getBins path entry;
      version =
        if isLink entry
        then let
          pjs = l.fromJSON (l.readFile (source + "/package.json"));
        in
          pjs.version
        else entry.version;
    in
      # Every other package
      {
        inherit name;
        value = {
          ${version} = {
            inherit info bins;
            dependencies = getDependencies lock path entry;
            # We need to determine the initial state of every package and
            # TODO: define dist and installed if they are in source form. We currently only do this for the root package.
            ${info.initialState} = source;
            public = {
              out = source;
              # TODO: I think this is a hack.
              inherit (source) drvPath name;
            };
          };
        };
      };

  /*
  Function that returns instructions to create the file system (aka. node_modules directory)
  Every `source` entry here is created. Bins are symlinked to their target.
  This behavior is implemented via the prepared-builder script.
  @argument pdefs'
  # The filtered and sanititized pdefs containing no cycles.
  # Only pdefs required by the current root and environment.
  # e.g. all buildtime dependencies of top-level package.
  ->
  fileSystem :: {
    "node_modules/typescript": {
      source: <derivation typescript-dist>
      bins: {
        "node_modules/.bin/tsc": "node_modules/typescript/bin/tsc"
      }
    }
  }
  */
  getFileSystem = pdefs':
    l.foldl' (
      res: name:
        res
        // l.mapAttrs' (version: entry: {
          name = entry.info.initialPath;
          value = {
            source = entry.dist;
            bins =
              l.mapAttrs' (name: target: {
                name = (builtins.dirOf entry.info.initialPath) + "/.bin/" + name;
                value = entry.info.initialPath + "/" + target;
              })
              pdefs'.${name}.${version}.bins;
          };
        }) (l.filterAttrs (n: value: value.info.initialState == "dist") pdefs'.${name})
    ) {} (l.attrNames pdefs');
in {
  inherit groups;

  imports = [
    ./interface.nix
    dream2nix.modules.dream2nix.mkDerivation
    dream2nix.modules.dream2nix.groups
  ];

  commonModule =
    (import ./types.nix {
      inherit
        lib
        dream2nix
        specialArgs
        ;
    })
    .pdefEntryOptions;

  # declare external dependencies
  deps = {nixpkgs, ...}: {
    inherit
      (nixpkgs)
      fetchurl
      jq
      tree
      ;
    nodejs = nixpkgs.nodejs_latest;
    inherit
      (nixpkgs.stdenv)
      mkDerivation
      ;
  };

  package-func.result = l.mkForce (config.groups.all.public.packages.${config.name}.${config.version});

  # OUTPUTS
  WIP-nodejs-builder-v3 = {
    inherit pdefs;
    packageLock =
      lib.mkDefault
      (builtins.fromJSON (builtins.readFile cfg.packageLockFile));
  };
}
