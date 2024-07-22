{ stdenv
, callPackage
, purifix-compiler
, writeShellScriptBin
, nodejs
, lib
, fromYAML
, purescript-registry
, purescript-registry-index
, purescript-language-server
, jq
, findutils
, esbuild
, runtimeShell
}:
{ localPackages
, package-config
, storage-backend
, develop-packages
, backends
, withDocs
, nodeModules
, copyFiles
}:
let
  linkFiles = callPackage ./link-files.nix { };
  workspace = package-config.workspace;
  yaml = package-config.config;
  package-set-config = workspace.package_set or workspace.set;
  extra-packages = (workspace.extra_packages or { }) // (lib.mapAttrs (_: x: x // { isLocal = true; }) localPackages);
  inherit (callPackage ./get-package-set.nix
    { inherit fromYAML purescript-registry purescript-registry-index; }
    {
      inherit package-set-config extra-packages;
      inherit (package-config) src repo;
    }) packages package-set;

  fetch-sources = callPackage ./fetch-sources.nix { };

  # Download the source code for each package in the transitive closure
  # of the build dependencies;
  build-closure = fetch-sources {
    inherit packages storage-backend;
    dependencies = [ yaml.package.name ]
      ++ (yaml.package.dependencies or [ ]);
  };

  # Download the source code for each package in the transitive closure
  # of the build and test dependencies;
  test-closure = fetch-sources {
    inherit packages storage-backend;
    dependencies = [ yaml.package.name ]
      ++ (yaml.package.test.dependencies or [ ])
      ++ (yaml.package.dependencies or [ ]);
  };

  package-set-closure = fetch-sources {
    inherit packages storage-backend;
    dependencies = builtins.attrNames packages;
  };

  all-locals = builtins.attrNames localPackages;
  locals = if develop-packages == null then all-locals else develop-packages;
  raw-develop-dependencies = builtins.concatLists (map (pkg: localPackages.${pkg}.config.package.dependencies) locals);
  develop-dependencies = builtins.filter (dep: !(builtins.elem dep locals)) raw-develop-dependencies;
  develop-closure = fetch-sources {
    inherit packages storage-backend;
    dependencies = develop-dependencies;
  };

  compiler-version = package-set.compiler;
  compiler = purifix-compiler compiler-version;

  make-pkgs = lib.makeOverridable (callPackage ./make-package-set.nix { inherit linkFiles; }) {
    backend = workspace.backend or { };
    inherit storage-backend
      packages
      compiler
      fetch-sources
      withDocs
      backends
      copyFiles
      ;
  };

  build-pkgs = make-pkgs build-pkgs build-closure.packages;

  test-pkgs = make-pkgs test-pkgs test-closure.packages;

  dev-shell-package = {
    pname = "purifix-dev-shell";
    version = "0.0.0";
    src = null;
    subdir = null;
    dependencies = develop-dependencies;
  };
  dev-pkgs = make-pkgs dev-pkgs (develop-closure.packages ++ [ dev-shell-package ]);

  pkgs = make-pkgs pkgs package-set-closure.packages;

  runMain = yaml.package.run.main or "Main";
  testMain = yaml.package.test.main or "Test.Main";
  backendCommand = yaml.pacakge.backend or "";
  codegen = if backendCommand == "" then "js" else "corefn";

  purifix = (writeShellScriptBin "purifix" ''
    mkdir -p output
    cp --no-clobber --preserve -r -L -t output ${dev-pkgs.purifix-dev-shell.deps}/output/*
    chmod -R +w output
    purs compile --codegen ${codegen} ${toString dev-pkgs.purifix-dev-shell.globs} "$@"
    ${backendCommand}
  '') // {
    globs = dev-pkgs.purifix-dev-shell.globs;
  };

  purifix-project =
    let
      relative = trail: lib.concatStringsSep "/" trail;
      projectGlobs = lib.mapAttrsToList (name: pkg: ''"''${PURIFIX_ROOT:-.}/${relative pkg.trail}/src/**/*.purs"'') localPackages;
    in
    writeShellScriptBin "purifix-project" ''
      purifix ${toString projectGlobs} "$@"
    '';

  run =
    let evaluate = "import {main} from 'file://$out/output/${runMain}/index.js'; main();";
    in stdenv.mkDerivation {
      pname = yaml.package.name;
      version = yaml.package.version or "0.0.0";
      phases = [ "installPhase" "fixupPhase" ];
      installPhase = ''
        mkdir $out
        mkdir $out/bin
        ${lib.optionalString (nodeModules != null) "ln -s ${nodeModules} $out/node_modules"}
        cp --preserve -L -rv ${build}/output $out/output
        echo "#!${runtimeShell}" >> $out/bin/${yaml.package.name}
        echo "${nodejs}/bin/node --use-openssl-ca --input-type=module --abort-on-uncaught-exception --trace-sigint --trace-uncaught --eval=\"${evaluate}\"" >> $out/bin/${yaml.package.name}
        chmod +x $out/bin/${yaml.package.name}
      '';
    };

  # TODO: figure out how to run tests with other backends, js only for now
  test =
    test-pkgs.${yaml.package.name}.overrideAttrs
      (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ nodejs ];
        buildPhase = ''
          purs compile ${toString old.passthru.globs} "${old.passthru.package.src}/${old.passthru.package.subdir or ""}/test/**/*.purs"
        '';
        installPhase = ''
          cp -r -L output test-output
          ${lib.optionalString (nodeModules != null) "ln -s ${nodeModules} node_modules"}
          node --input-type=module --abort-on-uncaught-exception --trace-sigint --trace-uncaught --eval="import {main} from './test-output/${testMain}/index.js'; main();" | tee $out
        '';
        fixupPhase = "#nothing to be done here";
      });

  docs = { format ? "html" }:
    let
      inherit (build-pkgs.${yaml.package.name}) globs;
    in
    stdenv.mkDerivation {
      name = "${yaml.package.name}-docs";
      src = package-config.src;
      nativeBuildInputs = [
        compiler
      ];
      buildPhase = ''
        mkdir output
        cp --no-clobber --preserve -r -L -t output ${build-pkgs.${yaml.package.name}.deps}/output/*
        chmod -R +w output
        purs docs --format ${format} ${toString globs} "$src/**/*.purs" --output docs
      '';
      installPhase = ''
        mv docs $out
      '';
    };


  develop =
    stdenv.mkDerivation {
      name = "develop-${yaml.package.name}";
      buildInputs = [
        compiler
        purescript-language-server
        purifix
        purifix-project
      ];
      shellHook = ''
        export PURS_IDE_SOURCES='${toString purifix.globs}'
      '';
    };

  build = build-pkgs.${yaml.package.name}.overrideAttrs
    (old: {
      fixupPhase = "# don't clear output directory";
      passthru = old.passthru // {
        inherit build test develop bundle docs run;
        bundle-default = bundle { };
        bundle-app = bundle { app = true; };
        package-set = pkgs;
      };
    });

  bundle =
    { minify ? false
    , format ? "iife"
    , app ? false
    , module ? runMain
    }: stdenv.mkDerivation {
      name = "bundle-${yaml.package.name}";
      phases = [ "buildPhase" "installPhase" ];
      nativeBuildInputs = [ esbuild ];
      buildPhase =
        let
          minification = lib.optionalString minify "--minify";
          moduleFile = "${build}/output/${module}/index.js";
          command = "esbuild --bundle --outfile=bundle.js --format=${format}";
        in
        if app
        then ''
          ${lib.optionalString (nodeModules != null) "export NODE_PATH=${nodeModules}:$NODE_PATH"}
          echo "import {main} from '${moduleFile}'; main()" | ${command} ${minification}
        ''
        else ''
          ${command} ${moduleFile}
        '';
      installPhase = ''
        mv bundle.js $out
      '';
    };
in
build
